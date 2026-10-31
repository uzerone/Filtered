import { byId } from "./catalog.js";
export const clone = (value) => structuredClone(value);
export const uid = () => crypto.randomUUID();
export function layer(kind, extra = {}) {
  return {
    id: uid(),
    name: kind[0].toUpperCase() + kind.slice(1),
    kind,
    isVisible: true,
    opacity: 1,
    blendMode: "normal",
    position: { x: 0.5, y: 0.5 },
    rotation: 0,
    ...extra,
  };
}
export function filterLayer(kind, values = {}) {
  if (!byId[kind]) throw new Error(`Unknown filter: ${kind}`);
  return layer("filter", {
    name: byId[kind].name,
    filter: {
      id: uid(),
      kind,
      isEnabled: true,
      parameters: {
        values: Object.fromEntries(
          byId[kind].params.map((p) => [
            p.key,
            {
              [p.kind === "pixelScalar" || p.kind === "choice"
                ? "scalar"
                : p.kind]: { _0: clone(values[p.key] ?? p.default) },
            },
          ]),
        ),
      },
    },
  });
}
export function valuesOf(filter) {
  return Object.fromEntries(
    Object.entries(filter.parameters.values).map(([k, v]) => [
      k,
      Object.values(v)[0]._0,
    ]),
  );
}
export function setValue(filter, key, value) {
  const spec = byId[filter.kind].params.find((p) => p.key === key);
  const type = ["pixelScalar", "choice"].includes(spec.kind)
    ? "scalar"
    : spec.kind;
  filter.parameters.values[key] = { [type]: { _0: value } };
}
export function newProject() {
  return {
    version: 1,
    app: "Filtered",
    author: "",
    snapshot: {
      canvas: {
        width: 1080,
        height: 1080,
        background: { solid: { _0: { r: 0, g: 0, b: 0, a: 1 } } },
        imageFit: "fit",
        dpi: 72,
        orientationQuarters: 0,
        flippedH: false,
      },
      layers: [],
      selectedLayerID: null,
    },
  };
}
export function allLayers(layers) {
  return layers.flatMap((l) => [l, ...allLayers(l.children || [])]);
}
export function locate(layers, id) {
  for (let i = 0; i < layers.length; i++) {
    if (layers[i].id === id)
      return { list: layers, index: i, layer: layers[i] };
    const child = locate(layers[i].children || [], id);
    if (child) return child;
  }
}
export function validateProject(input) {
  if (
    !input ||
    input.app !== "Filtered" ||
    input.version !== 1 ||
    !input.snapshot
  )
    throw new Error("This is not a supported Filtered project.");
  const c = input.snapshot.canvas;
  if (
    !c ||
    ![c.width, c.height].every(
      (n) => Number.isInteger(n) && n >= 1 && n <= 8192,
    )
  )
    throw new Error("Canvas dimensions must be between 1 and 8192 pixels.");
  const validColor = (value) =>
    value &&
    ["r", "g", "b", "a"].every(
      (key) => Number.isFinite(value[key]) && Math.abs(value[key]) <= 10,
    );
  if (
    !c.background ||
    (!c.background.transparent && !validColor(c.background.solid?._0))
  )
    throw new Error("Invalid canvas background.");
  if (!["fit", "fill", "stretch", "actual"].includes(c.imageFit))
    throw new Error("Invalid image placement.");
  for (const key of ["cropX", "cropY", "cropW", "cropH"]) {
    if (
      c[key] != null &&
      (!Number.isFinite(c[key]) ||
        c[key] < 0 ||
        c[key] > 1 ||
        (["cropW", "cropH"].includes(key) && c[key] === 0))
    )
      throw new Error("Invalid crop.");
  }
  const ids = new Set();
  let count = 0;
  const inspect = (layers, depth = 0) => {
    if (!Array.isArray(layers) || depth > 8)
      throw new Error("Invalid layer stack.");
    for (const l of layers) {
      if (
        ++count > 500 ||
        !["image", "filter", "text", "group"].includes(l.kind) ||
        typeof l.id !== "string" ||
        ids.has(l.id) ||
        typeof l.name !== "string" ||
        !Number.isFinite(l.position?.x) ||
        !Number.isFinite(l.position?.y) ||
        !Number.isFinite(l.rotation) ||
        !Number.isFinite(l.opacity) ||
        l.opacity < 0 ||
        l.opacity > 1
      )
        throw new Error("Invalid layer.");
      ids.add(l.id);
      if (l.kind === "filter") {
        if (!byId[l.filter?.kind] || !l.filter.parameters?.values)
          throw new Error(`Unsupported filter: ${l.filter?.kind}`);
        const v = valuesOf(l.filter);
        for (const p of byId[l.filter.kind].params) {
          if (v[p.key] === undefined)
            setValue(l.filter, p.key, clone(p.default));
          else if (
            ["scalar", "pixelScalar", "angle", "choice"].includes(p.kind) &&
            (!Number.isFinite(v[p.key]) || v[p.key] < p.min || v[p.key] > p.max)
          )
            throw new Error(`Invalid ${p.label} value.`);
          else if (p.kind === "color" && !validColor(v[p.key]))
            throw new Error(`Invalid ${p.label} color.`);
          else if (
            p.kind === "center" &&
            ![v[p.key]?.x, v[p.key]?.y].every(Number.isFinite)
          )
            throw new Error("Invalid filter center.");
        }
      }
      if (
        l.kind === "text" &&
        (typeof l.text?.string !== "string" ||
          !Number.isFinite(l.text.fontSize) ||
          l.text.fontSize < 1 ||
          l.text.fontSize > 4096 ||
          typeof l.text.fontName !== "string" ||
          !validColor(l.text.color) ||
          ![l.text.tracking, l.text.lineSpacing].every(Number.isFinite))
      )
        throw new Error("Invalid text layer.");
      if (l.children) inspect(l.children, depth + 1);
      if (
        l.watermark &&
        (l.kind !== "text" ||
          !Number.isFinite(l.watermark.spacing) ||
          l.watermark.spacing < 0.15 ||
          l.watermark.spacing > 0.75 ||
          typeof l.watermark.anchor !== "string")
      )
        throw new Error("Invalid watermark settings.");
    }
  };
  inspect(input.snapshot.layers);
  return input;
}
export class History {
  constructor() {
    this.past = [];
    this.future = [];
  }
  checkpoint(project) {
    this.past.push(clone(project));
    if (this.past.length > 60) this.past.shift();
    this.future = [];
  }
  undo(project) {
    if (!this.past.length) return project;
    this.future.push(clone(project));
    return this.past.pop();
  }
  redo(project) {
    if (!this.future.length) return project;
    this.past.push(clone(project));
    return this.future.pop();
  }
}
export function groupLayers(layers, ids) {
  // Only siblings can be grouped: preserves the stack's compositing order.
  const selected = layers.filter((l) => ids.includes(l.id));
  if (selected.length) {
    if (selected.length !== ids.length)
      throw new Error("Select layers within the same group.");
    const indices = selected.map((l) => layers.indexOf(l));
    if (indices.at(-1) - indices[0] + 1 !== indices.length)
      throw new Error(
        "Select adjacent layers to group without changing their order.",
      );
    const group = layer("group", { children: selected });
    layers.splice(indices[0], selected.length, group);
    return group;
  }
  for (const l of layers)
    if (l.children) {
      const result = groupLayers(l.children, ids);
      if (result) return result;
    }
}
