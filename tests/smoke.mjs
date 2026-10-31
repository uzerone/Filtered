import { _electron as electron } from "playwright";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
for (const f of ["catalog.js", "model.js", "engine.js"])
  await fs.copyFile("src/" + f, "dist/" + f);
const { build } = await import("esbuild");
await build({
  entryPoints: ["src/media.js"],
  bundle: true,
  format: "esm",
  outfile: "dist/media-test.js",
});
const packaged = process.env.FILTERED_EXECUTABLE;
const app = await electron.launch({
  ...(packaged ? { executablePath: path.resolve(packaged) } : {}),
  args: packaged ? [] : ["."],
  env: { ...process.env, FILTERED_TEST: "1" },
});
try {
  const page = await app.firstWindow();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.waitForSelector(".look-card");
  assert.equal(await page.locator(".look-card").count(), 20);
  assert.ok((await page.evaluate(() => window.desktop.fonts())).length > 0);
  await page.getByRole("button", { name: "T Text", exact: true }).click();
  await page.locator('[data-text="string"]').fill("Electron migration");
  await page.locator('[data-text="string"]').blur();
  await page.getByRole("button", { name: "Studio", exact: true }).click();
  assert.equal(await page.locator(".filter-card").count(), 51);
  await page.locator('[data-filter="invert"]').click();
  assert.equal(await page.locator(".layer").count(), 2);
  await app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows()[0].webContents.send("command", "undo"),
  );
  await page.waitForTimeout(200);
  assert.equal(await page.locator(".layer").count(), 1);
  await app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows()[0].webContents.send("command", "redo"),
  );
  await page.waitForTimeout(200);
  assert.equal(await page.locator(".layer").count(), 2);
  const saved = path.resolve("tests/roundtrip.ftrd"),
    exported = path.resolve("tests/export.png");
  // Import a deterministic PNG through the same main-process file handler as a native Open dialog.
  const sharp = (await import("sharp")).default;
  const png = await sharp({
    create: {
      width: 96,
      height: 64,
      channels: 4,
      background: { r: 90, g: 140, b: 210, alpha: 1 },
    },
  })
    .withMetadata({ density: 300 })
    .png()
    .toBuffer();
  await fs.writeFile("tests/fixture.png", png);
  await app.evaluate(({ dialog }, file) => {
    dialog.showOpenDialog = async () => ({
      canceled: false,
      filePaths: [file],
    });
    dialog.showMessageBox = async () => ({ response: 2 });
  }, path.resolve("tests/fixture.png"));
  await page.getByRole("button", { name: "Open…", exact: true }).click();
  await page.waitForFunction(() =>
    document.querySelector("#dimensions").textContent.includes("96 × 64"),
  );
  await page.locator('[data-filter="exposure"]').click();
  await page.locator('[data-param="inputEV"]').fill("1");
  await page.locator('[data-param="inputEV"]').dispatchEvent("change");
  await app.evaluate(({ dialog }, file) => {
    dialog.showSaveDialog = async () => ({ canceled: false, filePath: file });
  }, saved);
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await page.waitForFunction(
    () => document.querySelector("#status").textContent === "Project saved",
  );
  const data = JSON.parse(await fs.readFile(saved, "utf8"));
  assert.equal(data.snapshot.layers.length, 2);
  assert.ok(data.sourceImagePNG);
  assert.equal(data.snapshot.canvas.dpi, 300);
  assert.ok((await page.locator("#dimensions").textContent()).includes("300 DPI"));
  await app.evaluate(({ dialog }, file) => {
    dialog.showSaveDialog = async () => ({ canceled: false, filePath: file });
  }, exported);
  await page.getByRole("button", { name: "Export ↗", exact: true }).click();
  await page.locator("#modal-submit").click();
  await page.waitForFunction(
    () => document.querySelector("#status").textContent === "Export saved",
  );
  assert.equal((await sharp(exported).metadata()).width, 96);
  assert.equal((await sharp(exported).metadata()).density, 300);
  const rgb = await sharp(exported).raw().toBuffer();
  assert.ok(rgb[0] > 90, "Exposure must change exported pixels");
  if (!packaged) {
    // Exercise all kernels at preview and full resolution, including transparent input and GIF round-trip.
    const result = await page.evaluate(async () => {
      const { filters } = await import("/catalog.js");
      const { filterLayer, newProject, layer } = await import("/model.js");
      const { surface, applyFilter, render } = await import("/engine.js");
      const { encodeGIF, decodeAnimation } = await import("/media-test.js");
      const canvas = surface(48, 32),
        ctx = canvas.getContext("2d"),
        gradient = ctx.createLinearGradient(0, 0, 48, 32);
      gradient.addColorStop(0, "#163cba");
      gradient.addColorStop(1, "#f8b566");
      ctx.fillStyle = gradient;
      ctx.fillRect(0, 0, 48, 32);
      const tested = [];
      for (const f of filters) {
        for (const scale of [0.5, 1]) {
          const out = applyFilter(canvas, filterLayer(f.id).filter, scale);
          if (out.width !== 48 || out.height !== 32)
            throw new Error(f.id + " changed dimensions");
        }
        tested.push(f.id);
      }
      const p = newProject();
      p.snapshot.canvas.width = 48;
      p.snapshot.canvas.height = 32;
      p.snapshot.layers = [layer("image"), filterLayer("invert")];
      const bytes = await encodeGIF(
        p,
        [
          { image: canvas, delay: 70 },
          { image: canvas, delay: 120 },
        ],
        100,
      );
      const decoded = decodeAnimation(btoa(String.fromCharCode(...bytes)));
      return {
        tested,
        frames: decoded.length,
        delays: decoded.map((f) => f.delay),
        security: {
          node: typeof window.require,
          bridge: typeof window.desktop.open,
        },
      };
    });
    assert.equal(result.tested.length, 51);
    assert.equal(result.frames, 2);
    assert.deepEqual(result.delays, [70, 120]);
    assert.equal(result.security.node, "undefined");
    assert.equal(result.security.bridge, "function");
  }
  await page.getByRole("button", { name: "© Watermark", exact: true }).click();
  await page.locator('[data-text="string"]').fill("© Test Studio");
  await page.locator('[data-text="string"]').blur();
  await page.locator('[data-watermark="preset"]').selectOption("tiled");
  assert.equal(
    await page.locator('[data-watermark="repeat"]').isChecked(),
    true,
  );
  await page.locator('[data-watermark="preset"]').selectOption("signature");
  assert.equal(
    await page.locator('[data-text="string"]').inputValue(),
    "© Test Studio",
  );
  await page.getByRole("button", { name: "Top right", exact: true }).click();
  assert.equal(await page.locator('[data-position="x"]').inputValue(), "0.96");
  assert.equal(await page.locator('[data-position="y"]').inputValue(), "0.04");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await page.waitForTimeout(150);
  const withWatermark = JSON.parse(await fs.readFile(saved, "utf8"));
  const mark = withWatermark.snapshot.layers.at(-1);
  assert.equal(mark.text.string, "© Test Studio");
  assert.equal(mark.watermark.anchor, "top-right");
  assert.equal(mark.watermark.preset, "signature");
  await app.evaluate(({ dialog }, file) => {
    dialog.showOpenDialog = async () => ({
      canceled: false,
      filePaths: [file],
    });
  }, saved);
  await page.getByRole("button", { name: "Open…", exact: true }).click();
  await page.waitForFunction(
    () => document.querySelector("#status").textContent === "Project opened",
  );
  assert.equal(
    await page.locator('[data-text="string"]').inputValue(),
    "© Test Studio",
  );
  await app.evaluate(({ dialog }, file) => {
    dialog.showSaveDialog = async () => ({ canceled: false, filePath: file });
  }, exported);
  await page.getByRole("button", { name: "Export ↗", exact: true }).click();
  await page.locator("#modal-submit").click();
  await page.waitForFunction(
    () => document.querySelector("#status").textContent === "Export saved",
  );
  const markedRGB = await sharp(exported).raw().toBuffer();
  assert.notDeepEqual(
    markedRGB,
    rgb,
    "Watermark must be present in the exported pixels",
  );
  // Save cancel must keep the document dirty and prevent New from discarding it.
  await page.locator('[data-text="string"]').fill("Unsaved watermark");
  await page.locator('[data-text="string"]').blur();
  await app.evaluate(({ dialog }) => {
    dialog.showMessageBox = async () => ({ response: 0 });
    dialog.showSaveDialog = async () => ({ canceled: true });
  });
  // Force Save As to establish cancellation without overwriting the existing project.
  await app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows()[0].webContents.send("command", "save-as"),
  );
  await page.waitForTimeout(100);
  assert.ok((await page.locator("#document-name").textContent()).includes("•"));
  await app.evaluate(({ dialog }) => {
    dialog.showMessageBox = async () => ({ response: 1 });
  });
  await page.getByRole("button", { name: "New", exact: true }).click();
  assert.equal(
    await page.locator('[data-text="string"]').inputValue(),
    "Unsaved watermark",
  );
  await page.screenshot({ path: "tests/smoke.png" });
  assert.deepEqual(errors, []);
  console.log(
    packaged
      ? "Packaged Electron smoke passed: editing, file I/O, export, watermarks, unsaved changes."
      : "Electron smoke passed: editing, all filters, GIF, watermarks, project round-trip, unsaved changes.",
  );
  for (const file of [
    "tests/fixture.png",
    "tests/roundtrip.ftrd",
    "tests/export.png",
  ])
    await fs.rm(file, { force: true });
} finally {
  await app.evaluate(({ BrowserWindow }) => {
    for (const w of BrowserWindow.getAllWindows()) w.destroy();
  });
  await app.close();
  for (const f of ["catalog.js", "model.js", "engine.js", "media-test.js"])
    await fs.rm("dist/" + f, { force: true });
}
