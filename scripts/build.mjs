import { build } from "esbuild";
import { mkdir, copyFile, rm } from "node:fs/promises";
await rm("dist", { recursive: true, force: true });
await mkdir("dist", { recursive: true });
await build({
  entryPoints: ["src/app.js"],
  bundle: true,
  outfile: "dist/app.js",
  format: "esm",
  sourcemap: true,
  target: "chrome140",
});
for (const file of ["index.html", "style.css"])
  await copyFile(`src/${file}`, `dist/${file}`);
if (process.platform === "darwin") {
  const { execFileSync } = await import("node:child_process");
  execFileSync("xcrun", [
    "clang",
    "-fobjc-arc",
    "-O2",
    "-framework",
    "Foundation",
    "-framework",
    "AppKit",
    "-framework",
    "Vision",
    "-framework",
    "CoreImage",
    "-framework",
    "CoreVideo",
    "-framework",
    "CoreGraphics",
    "electron/native/cutout.m",
    "-o",
    "electron/native/cutout",
  ]);
}
