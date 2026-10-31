import test from "node:test";
import assert from "node:assert/strict";
import { filters } from "../src/catalog.js";
import { looks } from "../src/looks.js";
import {
  newProject,
  filterLayer,
  valuesOf,
  setValue,
  layer,
  validateProject,
  History,
  groupLayers,
  clone,
} from "../src/model.js";
test("all 51 filters and 20 Look recipes preserve Swift parameter encoding", () => {
  assert.equal(filters.length, 51);
  assert.equal(looks.length, 20);
  for (const f of filters) {
    const l = filterLayer(f.id);
    assert.equal(Object.keys(valuesOf(l.filter)).length, f.params.length);
    for (const p of f.params)
      assert.deepEqual(valuesOf(l.filter)[p.key], p.default);
  }
  for (const look of looks) {
    assert.ok(look.stack.length);
    for (const f of look.stack) {
      const l = filterLayer(f.kind, f.values);
      for (const [key, value] of Object.entries(f.values))
        assert.deepEqual(valuesOf(l.filter)[key], value);
    }
  }
});
test("legacy Swift v1 project round-trips groups, colors, source, crop and optional fields", () => {
  const project = newProject();
  project.sourceImagePNG = "encoded";
  project.snapshot.canvas.cropX = 0.1;
  project.snapshot.layers = [
    layer("image"),
    layer("group", {
      children: [
        filterLayer("levels", { inBlack: 0.2 }),
        filterLayer("gradientMap"),
      ],
    }),
  ];
  const loaded = validateProject(JSON.parse(JSON.stringify(project)));
  assert.deepEqual(loaded, project);
  assert.equal(
    valuesOf(loaded.snapshot.layers[1].children[0].filter).inBlack,
    0.2,
  );
});
test("undo and redo isolate nested filter changes and clear future after branching", () => {
  const h = new History(),
    p = newProject();
  p.snapshot.layers = [filterLayer("exposure")];
  h.checkpoint(p);
  setValue(p.snapshot.layers[0].filter, "inputEV", 2);
  const undone = h.undo(p);
  assert.equal(valuesOf(undone.snapshot.layers[0].filter).inputEV, 0);
  const redone = h.redo(undone);
  assert.equal(valuesOf(redone.snapshot.layers[0].filter).inputEV, 2);
  h.undo(redone);
  h.checkpoint(undone);
  assert.equal(h.future.length, 0);
});
test("grouping preserves order and rejects separated selection", () => {
  const layers = [layer("image"), filterLayer("gamma"), filterLayer("invert")],
    ids = layers.slice(1).map((l) => l.id);
  const original = clone(layers);
  const group = groupLayers(layers, ids);
  assert.deepEqual(group.children, original.slice(1));
  assert.equal(layers.length, 2);
  assert.throws(
    () => groupLayers(original, [original[0].id, original[2].id]),
    /adjacent/,
  );
});
test("invalid files fail before replacing an open document", () => {
  for (const value of [null, {}, { ...newProject(), version: 2 }])
    assert.throws(() => validateProject(value));
  const p = newProject();
  p.snapshot.canvas.width = 0;
  assert.throws(() => validateProject(p));
  p.snapshot.canvas.width = 100;
  p.snapshot.layers = [filterLayer("gamma")];
  setValue(p.snapshot.layers[0].filter, "inputPower", NaN);
  assert.throws(() => validateProject(p));
});

test("watermark presets preserve custom text and round-trip editable position and styling", async () => {
  const {
    createWatermark,
    watermarkPresets,
    applyWatermarkPreset,
    positionWatermark,
  } = await import("../src/watermarks.js");
  const p = newProject(),
    mark = createWatermark(p.snapshot.canvas, "© Example");
  p.snapshot.layers.push(mark);
  assert.deepEqual(mark.position, { x: 0.99, y: 0.99 });
  for (const preset of watermarkPresets) {
    applyWatermarkPreset(mark, preset.id, p.snapshot.canvas);
    assert.equal(mark.text.string, "© Example");
    assert.equal(mark.watermark.repeat, preset.id === "tiled");
    assert.deepEqual(validateProject(JSON.parse(JSON.stringify(p))), p);
  }
  positionWatermark(mark, "top-left");
  assert.deepEqual(mark.position, { x: 0.04, y: 0.04 });
  assert.equal(mark.text.alignment, "left");
  assert.throws(() => positionWatermark(mark, "offscreen"));
});
