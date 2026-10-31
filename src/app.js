import {
  watermarkPresets,
  watermarkPositions,
  createWatermark,
  applyWatermarkPreset,
  positionWatermark,
} from "./watermarks.js";
import { filters, byId } from "./catalog.js";
import { looks } from "./looks.js";
import {
  clone,
  uid,
  layer,
  filterLayer,
  valuesOf,
  setValue,
  newProject,
  allLayers,
  locate,
  validateProject,
  History,
  groupLayers,
} from "./model.js";
import { surface, render, histogram, cssColor } from "./engine.js";
import { loadImage, decodeAnimation, encodeGIF, pngBytes } from "./media.js";
const $ = (s) => document.querySelector(s),
  desktop = window.desktop;
let project = newProject(),
  history = new History(),
  source = null,
  cutoutSource = null,
  frames = [],
  frameIndex = 0,
  playing = false,
  timer = null,
  selected = [],
  mode = "presets",
  compare = false,
  zoom = "fit",
  name = "Untitled",
  saved = JSON.stringify(project),
  renderPending = false,
  lastRender = null,
  continuous = false;
let prefs = JSON.parse(
  localStorage.getItem("filtered.preferences") ||
    '{"author":"","watermark":"","quality":90}',
);
let customLooks = JSON.parse(localStorage.getItem("filtered.looks") || "[]");
let platform = await desktop.platform();
const systemFonts = await desktop.fonts();
const escape = (s) =>
  String(s).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const colorHex = (c) =>
  "#" +
  ["r", "g", "b"]
    .map((k) =>
      Math.round((c?.[k] ?? 0) * 255)
        .toString(16)
        .padStart(2, "0"),
    )
    .join("");
const fromHex = (h) => ({
  r: parseInt(h.slice(1, 3), 16) / 255,
  g: parseInt(h.slice(3, 5), 16) / 255,
  b: parseInt(h.slice(5, 7), 16) / 255,
  a: 1,
});
function status(text, error = false) {
  $("#status").textContent = text;
  $("#status").classList.toggle("error", error);
}
async function safe(fn) {
  try {
    return await fn();
  } catch (error) {
    status(error.message, true);
    console.error(error);
    return null;
  }
}
async function busy(fn) {
  document.body.classList.add("busy");
  try {
    return await fn();
  } finally {
    document.body.classList.remove("busy");
  }
}
function fingerprint(value) {
  const copy = {
    ...value,
    snapshot: { ...value.snapshot, selectedLayerID: null },
  };
  return JSON.stringify(copy);
}
function dirty() {
  return fingerprint(project) !== fingerprint(JSON.parse(saved));
}
function notify(extra = {}) {
  $("#document-name").textContent = name + (dirty() ? " •" : "");
  desktop.document({ dirty: dirty(), name, ...extra });
}
function checkpoint() {
  history.checkpoint(project);
}
function mutate(fn) {
  checkpoint();
  fn();
  update();
}
function selection() {
  return locate(project.snapshot.layers, selected.at(-1))?.layer;
}
function update() {
  selected = selected.filter((id) => locate(project.snapshot.layers, id));
  project.snapshot.selectedLayerID = selected.at(-1) ?? null;
  canvasControls();
  layerList();
  properties();
  scheduleRender();
  notify();
}
function scheduleRender() {
  if (renderPending) return;
  renderPending = true;
  requestAnimationFrame(() => {
    renderPending = false;
    safe(draw);
  });
}
function draw() {
  const start = performance.now();
  lastRender = render(
    project,
    !compare && project.snapshot.canvas.backgroundRemoved && cutoutSource
      ? cutoutSource
      : (frames[frameIndex]?.image ?? source),
    { original: compare },
  );
  const canvas = $("#preview");
  canvas.width = lastRender.width;
  canvas.height = lastRender.height;
  canvas.getContext("2d").drawImage(lastRender, 0, 0);
  $("#empty").hidden = !!source || project.snapshot.layers.length > 0;
  fitCanvas();
  drawHistogram();
  $("#dimensions").textContent =
    `${project.snapshot.canvas.width} × ${project.snapshot.canvas.height} px`;
  $("#render-time").textContent = `${Math.round(performance.now() - start)} ms`;
  $("#compare").classList.toggle("active", compare);
  $("#timeline").hidden = frames.length < 2;
  $("#frame").max = Math.max(0, frames.length - 1);
  $("#frame").value = frameIndex;
  $("#frame-label").textContent = `${frameIndex + 1} / ${frames.length}`;
}
function fitCanvas() {
  const c = project.snapshot.canvas,
    v = $("#viewport"),
    factor =
      zoom === "fit"
        ? Math.min(
            (v.clientWidth - 68) / c.width,
            (v.clientHeight - 68) / c.height,
          )
        : Number(zoom);
  $("#canvas-wrap").style.width = `${Math.max(1, c.width * factor)}px`;
  $("#canvas-wrap").style.height = `${Math.max(1, c.height * factor)}px`;
}
function drawHistogram() {
  if (!lastRender) return;
  const canvas = $("#histogram"),
    ctx = canvas.getContext("2d"),
    bins = histogram(lastRender),
    indices = $("#histogram-mode").value === "Luma" ? [3] : [0, 1, 2];
  ctx.clearRect(0, 0, 256, 64);
  const max = Math.max(1, ...indices.flatMap((i) => bins[i]));
  ctx.globalCompositeOperation = "screen";
  indices.forEach((i) => {
    ctx.fillStyle = ["#b65454aa", "#77b861aa", "#5b89d5aa", "#b5bdcaaa"][i];
    ctx.beginPath();
    ctx.moveTo(0, 64);
    bins[i].forEach((n, x) => ctx.lineTo(x, 64 - Math.sqrt(n / max) * 60));
    ctx.lineTo(256, 64);
    ctx.fill();
  });
  ctx.globalCompositeOperation = "source-over";
}
function control(label, html) {
  return `<label class="control"><span>${label}</span>${html}</label>`;
}
function select(options, value, attrs = "") {
  return `<select ${attrs}>${options
    .map((o) => {
      const [v, label] = Array.isArray(o) ? o : [o, o];
      return `<option value="${escape(v)}" ${v === value ? "selected" : ""}>${escape(label)}</option>`;
    })
    .join("")}</select>`;
}
function number(value, attrs = "") {
  return `<input type="number" value="${value}" ${attrs}>`;
}
function range(label, value, min, max, attrs = "") {
  return control(
    `${label}<output>${Number(value).toFixed(2)}</output>`,
    `<input type="range" min="${min}" max="${max}" step="${max - min > 100 ? 1 : 0.01}" value="${value}" ${attrs}>`,
  );
}
function canvasControls() {
  const c = project.snapshot.canvas;
  $("#canvas-controls").innerHTML =
    control(
      "Preset",
      select(
        [
          ["custom", "Custom"],
          ["1080,1080", "Square · 1080"],
          ["2048,2048", "Square · 2K"],
          ["4096,4096", "Square · 4K"],
          ["1920,1080", "Full HD · 16:9"],
          ["3840,2160", "4K UHD"],
          ["7680,4320", "8K UHD"],
          ["1080,1350", "Portrait · 4:5"],
          ["1080,1920", "Story · 9:16"],
          ["2480,3508", "A4 · 300 DPI"],
        ],
        `${c.width},${c.height}`,
        'data-canvas="preset"',
      ),
    ) +
    `<div class="row">${control("Width", number(c.width, 'min="1" max="8192" data-canvas="width"'))}${control("Height", number(c.height, 'min="1" max="8192" data-canvas="height"'))}</div>` +
    `<div class="row">${control("Placement", select(["fit", "fill", "stretch", "actual"], c.imageFit, 'data-canvas="imageFit"'))}${control("Background", select(["solid", "transparent"], c.background.solid ? "solid" : "transparent", 'data-canvas="background"'))}</div>` +
    (c.background.solid
      ? `<input aria-label="Canvas background color" type="color" value="${colorHex(c.background.solid._0)}" data-canvas="color">`
      : "");
}
function library() {
  const query = $("#search").value.toLowerCase(),
    list = $("#library-list");
  document
    .querySelectorAll("[data-mode]")
    .forEach((b) => b.classList.toggle("active", b.dataset.mode === mode));
  $("#search").placeholder =
    mode === "presets" ? "Search Looks…" : "Search filters…";
  if (mode === "presets") {
    const colors = [
      ["#273443", "#d5d0af"],
      ["#233073", "#ed8097"],
      ["#492344", "#4db3ac"],
      ["#5c1e63", "#64e8d9"],
      ["#cf643d", "#e8cf73"],
      ["#497a6b", "#badb92"],
    ];
    list.innerHTML = [...looks, ...customLooks]
      .filter((l) => l.name.toLowerCase().includes(query))
      .map(
        (l, i) =>
          `<button class="look-card" data-look="${escape(l.id)}"><span class="swatch" style="--c1:${colors[i % 6][0]};--c2:${colors[i % 6][1]}">Aa</span><span class="label">${escape(l.name)}</span></button>`,
      )
      .join("");
  } else
    list.innerHTML = [
      "adjust",
      "film",
      "sharpen",
      "halftone",
      "pixelate",
      "distort",
      "stylize",
      "glitch",
    ]
      .map((f) => {
        const matches = filters.filter(
          (x) => x.family === f && x.name.toLowerCase().includes(query),
        );
        return matches.length
          ? `<div class="filter-family">${f}</div>` +
              matches
                .map(
                  (x) =>
                    `<button class="filter-card" data-filter="${x.id}">${x.name}<span>＋</span></button>`,
                )
                .join("")
          : "";
      })
      .join("");
}
function layerList() {
  const list = (layers, depth = 0) =>
    [...layers]
      .reverse()
      .map(
        (l) =>
          `<div class="layer ${selected.includes(l.id) ? "selected" : ""}" data-layer="${l.id}" style="margin-left:${depth * 12}px" draggable="true"><button data-visible="${l.id}" aria-label="${l.isVisible ? "Hide" : "Show"} ${escape(l.name)}">${l.isVisible ? "◉" : "○"}</button><span class="layer-name">${escape(l.name)}</span><span class="kind">${{ image: "IMG", text: "TXT", filter: "FX", group: "GRP" }[l.kind]}</span><button data-move="${l.id}" data-direction="1" aria-label="Move up">↑</button><button data-move="${l.id}" data-direction="-1" aria-label="Move down">↓</button></div>` +
          (l.children ? list(l.children, depth + 1) : ""),
      )
      .join("");
  $("#layers").innerHTML =
    list(project.snapshot.layers) || '<p class="muted">No layers</p>';
}
function properties() {
  const l = selection();
  if (!l) {
    $("#properties").innerHTML = '<p class="muted">No layer selected</p>';
    return;
  }
  let html =
    control("Name", `<input value="${escape(l.name)}" data-prop="name">`) +
    range("Opacity", l.opacity, 0, 1, 'data-prop="opacity"') +
    control(
      "Blend mode",
      select(
        [
          "normal",
          "multiply",
          "screen",
          "overlay",
          "softLight",
          "darken",
          "lighten",
          "difference",
        ],
        l.blendMode ?? "normal",
        'data-prop="blendMode"',
      ),
    );
  if (l.kind === "filter") {
    const v = valuesOf(l.filter);
    for (const p of byId[l.filter.kind].params) {
      const attrs = `data-param="${p.key}"`;
      if (p.kind === "bool")
        html += `<label class="check"><input type="checkbox" ${v[p.key] ? "checked" : ""} ${attrs}>${p.label}</label>`;
      else if (p.kind === "choice")
        html += control(
          p.label,
          select(
            p.choices.map((x, i) => [String(i), x]),
            String(v[p.key]),
            attrs,
          ),
        );
      else if (p.kind === "color")
        html += control(
          p.label,
          `<input type="color" value="${colorHex(v[p.key])}" ${attrs}>`,
        );
      else if (p.kind === "center")
        html += `<div class="row">${control("Center X", number(v[p.key].x, `${attrs} data-axis="x"`))}${control("Center Y", number(v[p.key].y, `${attrs} data-axis="y"`))}</div>`;
      else html += range(p.label, v[p.key], p.min, p.max, attrs);
    }
    html += '<button data-action="reset-filter">Reset filter</button>';
  }
  if (l.watermark) {
    html += control(
      "Watermark preset",
      select(
        watermarkPresets.map((p) => [p.id, p.name]),
        l.watermark.preset,
        'data-watermark="preset"',
      ),
    );
    html +=
      '<div class="control"><span>Position</span><div class="position-grid">' +
      watermarkPositions
        .map(
          ([id, label, icon]) =>
            `<button data-watermark-position="${id}" class="${l.watermark.anchor === id ? "active" : ""}" aria-label="${label}">${icon}</button>`,
        )
        .join("") +
      "</div></div>";
    html += `<label class="check"><input type="checkbox" data-watermark="repeat" ${l.watermark.repeat ? "checked" : ""}>Repeat watermark</label>`;
    if (l.watermark.repeat)
      html += range(
        "Tile spacing",
        l.watermark.spacing,
        0.15,
        0.75,
        'data-watermark="spacing"',
      );
  }
  if (l.kind === "text") {
    const t = l.text;
    html +=
      control(
        "Text",
        `<textarea data-text="string">${escape(t.string)}</textarea>`,
      ) +
      control(
        "Font",
        `<input data-text="fontName" value="${escape(t.fontName)}" list="fonts"><datalist id="fonts">${[...systemFonts, ...(project.fonts || []).map((f) => f.name)].map((f) => `<option value="${escape(f)}">`).join("")}</datalist>`,
      ) +
      `<button data-action="font">Import font…</button><div class="row">${control("Size", number(t.fontSize, 'min="1" max="4096" data-text="fontSize"'))}${control("Color", `<input type="color" value="${colorHex(t.color)}" data-text="color">`)}</div>` +
      control(
        "Alignment",
        select(
          ["left", "center", "right"],
          t.alignment,
          'data-text="alignment"',
        ),
      ) +
      `<div class="row">${control("Tracking", number(t.tracking, 'min="-100" max="500" data-text="tracking"'))}${control("Line spacing", number(t.lineSpacing, 'min="-100" max="1000" data-text="lineSpacing"'))}</div>` +
      control(
        "Wrap width (0 = auto)",
        number(t.boxWidth ?? 0, 'min="0" max="8192" data-text="boxWidth"'),
      ) +
      range("Horizontal position", l.position.x, 0, 1, 'data-position="x"') +
      range("Vertical position", l.position.y, 0, 1, 'data-position="y"') +
      range("Rotation", l.rotation, -Math.PI, Math.PI, 'data-prop="rotation"');
  }
  if (l.kind === "group")
    html += '<button data-action="ungroup">Ungroup layers</button>';
  $("#properties").innerHTML = html;
}
function insert(l) {
  const location = locate(project.snapshot.layers, selected.at(-1));
  if (location?.layer.kind === "group") location.layer.children.push(l);
  else if (location) location.list.splice(location.index + 1, 0, l);
  else project.snapshot.layers.push(l);
  selected = [l.id];
}
async function modal(title, html, submit = "Apply") {
  stop();
  $("#modal-title").textContent = title;
  $("#modal-content").innerHTML = html;
  $("#modal-submit").textContent = submit;
  $("#modal").returnValue = "";
  $("#modal").showModal();
  return new Promise((resolve) =>
    $("#modal").addEventListener(
      "close",
      () =>
        resolve(
          $("#modal").returnValue === "ok"
            ? Object.fromEntries(new FormData($("#modal-form")))
            : null,
        ),
      { once: true },
    ),
  );
}
async function confirmDiscard() {
  if (!dirty()) return true;
  const result = await desktop.confirm();
  return result === "discard" || (result === "save" && (await save()));
}
async function save(as = false) {
  project.author = prefs.author;
  const result = await desktop.save(JSON.stringify(project), as);
  if (!result) return false;
  name = result;
  saved = JSON.stringify(project);
  notify();
  status("Project saved");
  return true;
}
async function restoreMedia() {
  source = project.sourceImagePNG
    ? await loadImage(project.sourceImagePNG)
    : null;
  frames = project.sourceAnimatedData
    ? decodeAnimation(project.sourceAnimatedData)
    : [];
  cutoutSource = project.cutoutPNG ? await loadImage(project.cutoutPNG) : null;
  if (project.snapshot.canvas.backgroundRemoved && !cutoutSource && source) {
    status("Restoring subject cutout…");
    project.cutoutPNG = await desktop.cutout(project.sourceImagePNG);
    cutoutSource = await loadImage(project.cutoutPNG);
  }
  frameIndex = 0;
  await loadFonts();
}
async function loadFonts(document = project) {
  for (const f of document.fonts ?? []) {
    const font = new FontFace(f.name, `url(data:font/ttf;base64,${f.data})`);
    await font.load();
    document.fonts.add(font);
  }
}
async function openData(data) {
  if (!data) return;
  if (!(await confirmDiscard())) return;
  stop();
  let next, nextSource, nextFrames;
  if (data.type === "project") {
    next = validateProject(JSON.parse(data.text));
    nextSource = next.sourceImagePNG
      ? await loadImage(next.sourceImagePNG)
      : null;
    nextFrames = next.sourceAnimatedData
      ? decodeAnimation(next.sourceAnimatedData)
      : [];
  } else {
    nextSource = await loadImage(data.png);
    nextFrames = data.animated ? decodeAnimation(data.animated) : [];
    next = newProject();
    next.sourceImagePNG = data.png;
    next.sourceAnimatedData = data.animated;
    next.sourcePixelWidth = nextSource.width;
    next.sourcePixelHeight = nextSource.height;
    const fit = Math.min(
      1,
      8192 / Math.max(nextSource.width, nextSource.height),
    );
    next.snapshot.canvas.width = Math.round(nextSource.width * fit);
    next.snapshot.canvas.height = Math.round(nextSource.height * fit);
    next.snapshot.layers = [layer("image", { name: data.name })];
  }
  if (next.snapshot.canvas.backgroundRemoved && !next.cutoutPNG && nextSource) {
    status("Restoring subject cutout…");
    next.cutoutPNG = await desktop.cutout(next.sourceImagePNG);
  }
  const nextCutout = next.cutoutPNG ? await loadImage(next.cutoutPNG) : null;
  await loadFonts(next);
  project = next;
  source = nextSource;
  frames = nextFrames;
  frameIndex = 0;
  cutoutSource = nextCutout;
  history = new History();
  selected = [
    project.snapshot.selectedLayerID || project.snapshot.layers.at(-1)?.id,
  ].filter(Boolean);
  name = data.name;
  saved =
    data.type === "project"
      ? JSON.stringify(project)
      : JSON.stringify(newProject());
  notify({ openPath: data.path, resetPath: data.type !== "project" });
  update();
  status(data.type === "project" ? "Project opened" : "Image imported");
}
function stop() {
  playing = false;
  clearTimeout(timer);
  $("#play").textContent = "▶";
}
function play() {
  if (playing) {
    stop();
    return;
  }
  if (frames.length < 2) return;
  playing = true;
  $("#play").textContent = "❚❚";
  const tick = () => {
    if (!playing) return;
    frameIndex = (frameIndex + 1) % frames.length;
    scheduleRender();
    timer = setTimeout(tick, frames[frameIndex].delay);
  };
  timer = setTimeout(tick, frames[frameIndex].delay);
}
function exportProject(options) {
  const p = clone(project);
  p.snapshot.canvas.width = Number(options.width);
  p.snapshot.canvas.height = Number(options.height);
  scaleLayers(
    p.snapshot.layers,
    p.snapshot.canvas.width / project.snapshot.canvas.width,
  );
  return p;
}
async function exportImage() {
  const c = project.snapshot.canvas;
  const options = await modal(
    "Export image",
    control(
      "Format",
      select(
        [
          "png",
          "jpeg",
          "webp",
          "tiff",
          "gif",
          ...(platform === "darwin" ? ["heic"] : []),
        ],
        "png",
        'name="format"',
      ),
    ) +
      `<div class="row">${control("Width", number(c.width, 'name="width" min="1" max="8192" required'))}${control("Height", number(c.height, 'name="height" min="1" max="8192" required'))}</div>` +
      control(
        "Quality",
        number(prefs.quality, 'name="quality" min="1" max="100" required'),
      ) +
      control("DPI", number(c.dpi, 'name="dpi" min="1" max="1200" required')) +
      '<label class="check"><input type="checkbox" name="batch">Also export @2× and @3× (still formats)</label>',
    "Export",
  );
  if (!options) return;
  await busy(async () => {
    const p = exportProject(options),
      max = Math.max(p.snapshot.canvas.width, p.snapshot.canvas.height);
    if (options.batch && options.format !== "gif" && max * 3 > 8192)
      throw new Error("Batch exports must stay within 8192 pixels per side.");
    status("Rendering export…");
    await new Promise((r) => setTimeout(r, 20));
    const src =
      project.snapshot.canvas.backgroundRemoved && cutoutSource
        ? cutoutSource
        : (frames[frameIndex]?.image ?? source);
    const bytes =
      options.format === "gif"
        ? await encodeGIF(
            p,
            frames.length ? frames : [{ image: src, delay: 100 }],
            8192,
            (i, n) => status(`Rendering GIF ${i} / ${n}…`),
          )
        : await pngBytes(render(p, src, { maxSize: 8192 }));
    const batch = [];
    if (options.batch && options.format !== "gif")
      for (const scale of [2, 3]) {
        const scaled = clone(p);
        scaled.snapshot.canvas.width *= scale;
        scaled.snapshot.canvas.height *= scale;
        scaleLayers(scaled.snapshot.layers, scale);
        batch.push({
          scale,
          bytes: await pngBytes(render(scaled, src, { maxSize: 8192 })),
        });
      }
    const ok = await desktop.export({
      bytes,
      format: options.format,
      quality: Number(options.quality),
      dpi: Number(options.dpi),
      author: prefs.author,
      name,
      batch,
    });
    status(ok ? "Export saved" : "Export canceled");
  });
}
function scaleLayers(layers, scale) {
  for (const l of layers) {
    if (l.text) {
      l.text.fontSize *= scale;
      l.text.tracking *= scale;
      l.text.lineSpacing *= scale;
      if (l.text.boxWidth) l.text.boxWidth *= scale;
    }
    if (l.filter) {
      const v = valuesOf(l.filter);
      for (const spec of byId[l.filter.kind].params)
        if (spec.kind === "pixelScalar")
          setValue(l.filter, spec.key, v[spec.key] * scale);
        else if (spec.kind === "center")
          setValue(l.filter, spec.key, {
            x: v[spec.key].x * scale,
            y: v[spec.key].y * scale,
          });
    }
    if (l.children) scaleLayers(l.children, scale);
  }
}
const actions = {
  new: async () => {
    if (!(await confirmDiscard())) return;
    stop();
    project = newProject();
    history = new History();
    source = null;
    cutoutSource = null;
    frames = [];
    selected = [];
    name = "Untitled";
    saved = JSON.stringify(project);
    notify({ resetPath: true });
    update();
  },
  open: async () => openData(await desktop.open()),
  save: () => save(),
  "save-as": () => save(true),
  "open-file": openData,
  export: exportImage,
  close: async () => {
    if (await confirmDiscard()) await desktop.close();
  },
  undo: async () => {
    stop();
    project = history.undo(project);
    selected = [project.snapshot.selectedLayerID].filter(Boolean);
    await restoreMedia();
    update();
  },
  redo: async () => {
    stop();
    project = history.redo(project);
    selected = [project.snapshot.selectedLayerID].filter(Boolean);
    await restoreMedia();
    update();
  },
  watermark: () =>
    mutate(() => {
      const item = createWatermark(
        project.snapshot.canvas,
        prefs.author ? `© ${prefs.author}` : "© Your name",
      );
      project.snapshot.layers.push(item);
      selected = [item.id];
    }),
  text: () =>
    mutate(() =>
      insert(
        layer("text", {
          name: "Text",
          text: {
            string: "Your text",
            fontName: "Arial",
            fontSize: 64,
            color: { r: 1, g: 1, b: 1, a: 1 },
            alignment: "center",
            tracking: 0,
            lineSpacing: 0,
          },
        }),
      ),
    ),
  delete: () =>
    mutate(() => {
      for (const id of selected) {
        const found = locate(project.snapshot.layers, id);
        if (found) found.list.splice(found.index, 1);
      }
      selected = [];
    }),
  duplicate: () =>
    mutate(() => {
      const l = selection();
      if (!l) return;
      const dupe = clone(l);
      for (const item of allLayers([dupe])) {
        item.id = uid();
        if (item.filter) item.filter.id = uid();
      }
      dupe.name += " copy";
      insert(dupe);
    }),
  group: () => {
    if (!selected.length) return;
    mutate(() => {
      const group = groupLayers(project.snapshot.layers, selected);
      if (group) selected = [group.id];
    });
  },
  ungroup: () =>
    mutate(() => {
      const location = locate(project.snapshot.layers, selected.at(-1));
      if (location?.layer.kind === "group") {
        location.list.splice(location.index, 1, ...location.layer.children);
        selected = location.layer.children.map((l) => l.id);
      }
    }),
  rotate: () =>
    mutate(() => {
      const c = project.snapshot.canvas;
      c.orientationQuarters = ((c.orientationQuarters ?? 0) + 1) % 4;
      [c.width, c.height] = [c.height, c.width];
      for (const k of ["cropX", "cropY", "cropW", "cropH"]) delete c[k];
    }),
  flip: () =>
    mutate(
      () =>
        (project.snapshot.canvas.flippedH = !project.snapshot.canvas.flippedH),
    ),
  compare: () => {
    compare = !compare;
    scheduleRender();
  },
  fit: () => {
    zoom = "fit";
    $("#zoom").value = "fit";
    fitCanvas();
  },
  play,
  paste: async () => openData(await desktop.paste()),
  copy: async () => {
    await desktop.copy(
      await pngBytes(
        render(
          project,
          project.snapshot.canvas.backgroundRemoved && cutoutSource
            ? cutoutSource
            : (frames[frameIndex]?.image ?? source),
          { maxSize: 8192 },
        ),
      ),
    );
    status("Image copied");
  },
  "reset-filter": () =>
    mutate(() => {
      const l = selection();
      if (l?.filter) l.filter = filterLayer(l.filter.kind).filter;
    }),
  "save-look": async () => {
    const stack = allLayers(project.snapshot.layers)
      .filter((l) => l.kind === "filter")
      .map((l) => ({ kind: l.filter.kind, values: valuesOf(l.filter) }));
    if (!stack.length) {
      status("Add filters before saving a Look.");
      return;
    }
    const result = await modal(
      "Save Look",
      control("Name", '<input name="name" required maxlength="80" autofocus>'),
      "Save",
    );
    if (result) {
      customLooks.push({ id: uid(), name: result.name, stack });
      localStorage.setItem("filtered.looks", JSON.stringify(customLooks));
      library();
      status("Look saved");
    }
  },
  settings: async () => {
    const result = await modal(
      "Export preferences",
      control(
        "Author credit",
        `<input name="author" value="${escape(prefs.author)}">`,
      ) +
        control(
          "Default quality",
          number(prefs.quality, 'name="quality" min="1" max="100"'),
        ),
      "Save",
    );
    if (result) {
      prefs = { ...result, quality: Number(result.quality) };
      localStorage.setItem("filtered.preferences", JSON.stringify(prefs));
    }
  },
  font: async () => {
    const f = await desktop.font();
    if (!f) return;
    const font = new FontFace(f.name, `url(data:font/ttf;base64,${f.data})`);
    await font.load();
    document.fonts.add(font);
    mutate(() => {
      project.fonts ??= [];
      project.fonts.push(f);
      if (selection()?.text) selection().text.fontName = f.name;
    });
  },
  cutout: async () => {
    if (!source) {
      status("Open an image first.");
      return;
    }
    if (frames.length) {
      status("Subject cutout currently supports still images.");
      return;
    }
    if (project.snapshot.canvas.backgroundRemoved) {
      mutate(() => (project.snapshot.canvas.backgroundRemoved = false));
      return;
    }
    await busy(async () => {
      status("Finding the subject…");
      const png = await desktop.cutout(project.sourceImagePNG),
        img = await loadImage(png);
      mutate(() => {
        project.cutoutPNG = png;
        cutoutSource = img;
        project.snapshot.canvas.backgroundRemoved = true;
        project.snapshot.canvas.background = { transparent: {} };
      });
      status("Subject cut out");
    });
  },
  crop: async () => {
    const c = project.snapshot.canvas;
    const result = await modal(
      "Crop image",
      control(
        "Aspect ratio",
        select(
          ["custom", "1:1", "4:5", "9:16", "16:9", "3:2"],
          "custom",
          'name="aspect"',
        ),
      ) +
        `<div class="row">${control("Left (%)", number((c.cropX ?? 0) * 100, 'name="x" min="0" max="99" step="0.1"'))}${control("Top (%)", number((1 - (c.cropY ?? 0) - (c.cropH ?? 1)) * 100, 'name="y" min="0" max="99" step="0.1"'))}</div><div class="row">${control("Width (%)", number((c.cropW ?? 1) * 100, 'name="w" min="1" max="100" step="0.1"'))}${control("Height (%)", number((c.cropH ?? 1) * 100, 'name="h" min="1" max="100" step="0.1"'))}</div><label class="check"><input name="reset" type="checkbox">Reset crop</label>`,
    );
    if (!result) return;
    mutate(() => {
      if (result.reset) {
        for (const k of ["cropX", "cropY", "cropW", "cropH"]) delete c[k];
        return;
      }
      let x = Number(result.x) / 100,
        y = Number(result.y) / 100,
        w = Math.min(Number(result.w) / 100, 1 - x),
        h = Math.min(Number(result.h) / 100, 1 - y);
      if (result.aspect !== "custom") {
        const [a, b] = result.aspect.split(":").map(Number),
          q = (c.orientationQuarters ?? 0) % 2,
          sw = q ? (source?.height ?? c.height) : (source?.width ?? c.width),
          sh = q ? (source?.width ?? c.width) : (source?.height ?? c.height);
        w = Math.min(1, a / b / (sw / sh));
        h = Math.min(1, sw / sh / (a / b));
        x = (1 - w) / 2;
        y = (1 - h) / 2;
      }
      Object.assign(c, { cropX: x, cropY: 1 - y - h, cropW: w, cropH: h });
    });
  },
  enhance: () => {
    if (!source) {
      status("Open an image first.");
      return;
    }
    mutate(() => {
      const bins = histogram(source),
        total = Math.max(
          1,
          bins[3].reduce((a, b) => a + b, 0),
        ),
        percentile = (q) => {
          let sum = 0;
          for (let i = 0; i < 256; i++) {
            sum += bins[3][i];
            if (sum >= total * q) return i / 255;
          }
          return 1;
        };
      const means = bins
        .slice(0, 3)
        .map((b) => b.reduce((sum, n, i) => sum + n * i, 0) / total);
      insert(
        filterLayer("levels", {
          inBlack: Math.min(0.3, percentile(0.01)),
          inWhite: Math.max(0.7, percentile(0.99)),
        }),
      );
      insert(
        filterLayer("whiteBalance", {
          temp: Math.max(
            2500,
            Math.min(12000, 6500 + (means[2] - means[0]) * 35),
          ),
        }),
      );
      insert(
        filterLayer("highlightShadow", {
          inputShadowAmount: 0.2,
          inputHighlightAmount: 0.9,
        }),
      );
      insert(filterLayer("vibrance", { inputAmount: 0.18 }));
    });
    status("Auto Enhance added editable adjustment layers");
  },
};
async function command(action, data) {
  await safe(() => actions[action]?.(data));
}
desktop.onCommand(command);
document.addEventListener("click", (event) => {
  const button = event.target.closest("button");
  if (button?.dataset.action) {
    command(button.dataset.action);
    return;
  }
  if (button?.dataset.mode) {
    mode = button.dataset.mode;
    library();
    return;
  }
  if (button?.dataset.filter) {
    mutate(() => insert(filterLayer(button.dataset.filter)));
    return;
  }
  if (button?.dataset.look) {
    const look = [...looks, ...customLooks].find(
      (l) => l.id === button.dataset.look,
    );
    mutate(() => {
      project.snapshot.layers = project.snapshot.layers.filter(
        (l) => !l.presetLook,
      );
      const group = layer("group", {
        name: look.name,
        presetLook: true,
        children: look.stack.map((f) => filterLayer(f.kind, f.values)),
      });
      project.snapshot.layers.push(group);
      selected = [group.id];
    });
    return;
  }
  if (button?.dataset.visible) {
    mutate(() => {
      const l = locate(project.snapshot.layers, button.dataset.visible).layer;
      l.isVisible = !l.isVisible;
    });
    return;
  }
  if (button?.dataset.watermarkPosition) {
    mutate(() => {
      const item = selection();
      if (item?.watermark)
        positionWatermark(item, button.dataset.watermarkPosition);
    });
    return;
  }
  if (button?.dataset.move) {
    mutate(() => {
      const f = locate(project.snapshot.layers, button.dataset.move),
        to = f.index + Number(button.dataset.direction);
      if (to >= 0 && to < f.list.length) {
        f.list.splice(f.index, 1);
        f.list.splice(to, 0, f.layer);
      }
    });
    return;
  }
  const row = event.target.closest("[data-layer]");
  if (row) {
    if (event.metaKey || event.ctrlKey)
      selected = selected.includes(row.dataset.layer)
        ? selected.filter((id) => id !== row.dataset.layer)
        : [...selected, row.dataset.layer];
    else selected = [row.dataset.layer];
    project.snapshot.selectedLayerID = selected.at(-1) ?? null;
    layerList();
    properties();
  }
});
function editInput(input) {
  const d = input.dataset;
  if (
    !["canvas", "prop", "param", "text", "position", "watermark"].some(
      (k) => k in d,
    )
  )
    return;
  if (!continuous) {
    checkpoint();
    continuous = true;
  }
  let value =
    input.type === "checkbox"
      ? input.checked
      : input.type === "number" || input.type === "range"
        ? Number(input.value)
        : input.value;
  if (typeof value === "number" && !Number.isFinite(value)) return;
  const l = selection(),
    c = project.snapshot.canvas;
  if (d.canvas) {
    if (d.canvas === "preset") {
      if (value === "custom") return;
      [c.width, c.height] = value.split(",").map(Number);
    } else if (d.canvas === "width" || d.canvas === "height")
      c[d.canvas] = Math.max(1, Math.min(8192, Math.round(value)));
    else if (d.canvas === "background")
      c.background =
        value === "solid"
          ? { solid: { _0: { r: 0, g: 0, b: 0, a: 1 } } }
          : { transparent: {} };
    else if (d.canvas === "color")
      c.background = { solid: { _0: fromHex(value) } };
    else c[d.canvas] = value;
  }
  if (l?.watermark && d.watermark) {
    if (d.watermark === "preset") applyWatermarkPreset(l, value, c);
    else l.watermark[d.watermark] = value;
  }
  if (l && d.prop) l[d.prop] = value;
  if (l && d.position) l.position[d.position] = value;
  if (l?.filter && d.param) {
    const p = byId[l.filter.kind].params.find((p) => p.key === d.param);
    if (d.axis) value = { ...valuesOf(l.filter)[d.param], [d.axis]: value };
    else if (p.kind === "color") value = fromHex(value);
    else if (p.kind === "choice") value = Number(value);
    setValue(l.filter, d.param, value);
  }
  if (l?.text && d.text) {
    if (d.text === "color") value = fromHex(value);
    if (d.text === "fontSize") value = Math.max(1, Math.min(4096, value));
    if (d.text === "boxWidth" && !value) value = null;
    l.text[d.text] = value;
  }
  const output = input.closest(".control")?.querySelector("output");
  if (output) output.textContent = Number(value).toFixed(2);
  scheduleRender();
  notify();
}
document.addEventListener("input", (event) => {
  if (event.target.id === "search") {
    library();
    return;
  }
  if (event.target.id === "frame") {
    stop();
    frameIndex = Number(event.target.value);
    scheduleRender();
    return;
  }
  safe(() => editInput(event.target));
});
document.addEventListener("change", (event) => {
  if (event.target.id === "zoom") {
    zoom = event.target.value;
    fitCanvas();
    return;
  }
  if (event.target.id === "histogram-mode") {
    drawHistogram();
    return;
  }
  if (
    event.target.matches(
      "[data-canvas],[data-prop],[data-param],[data-text],[data-position],[data-watermark]",
    )
  ) {
    continuous = false;
    update();
  }
});
document.addEventListener("focusout", () => {
  continuous = false;
});
document.addEventListener("keydown", (event) => {
  if (event.target.matches("input,textarea,select") || $("#modal").open) return;
  if (event.key === "Delete" || event.key === "Backspace") {
    event.preventDefault();
    command("delete");
  }
  if (event.code === "Space") {
    event.preventDefault();
    if (frames.length) play();
    else {
      compare = true;
      scheduleRender();
    }
  }
});
document.addEventListener("keyup", (event) => {
  if (event.code === "Space" && !frames.length) {
    compare = false;
    scheduleRender();
  }
});
window.addEventListener("blur", () => {
  if (compare) {
    compare = false;
    scheduleRender();
  }
});
document.addEventListener("paste", (event) => {
  if (event.target.matches("input,textarea")) return;
  event.preventDefault();
  command("paste");
});
let dragLayer = null;
$("#layers").addEventListener("dragstart", (event) => {
  dragLayer = event.target.closest("[data-layer]")?.dataset.layer;
  event.dataTransfer.setData("text/plain", dragLayer ?? "");
});
$("#layers").addEventListener("dragover", (event) => event.preventDefault());
$("#layers").addEventListener("drop", (event) => {
  event.preventDefault();
  event.stopPropagation();
  const target = event.target.closest("[data-layer]")?.dataset.layer;
  if (!dragLayer || !target || target === dragLayer) return;
  mutate(() => {
    const from = locate(project.snapshot.layers, dragLayer),
      to = locate(project.snapshot.layers, target);
    if (from.list !== to.list) return;
    from.list.splice(from.index, 1);
    from.list.splice(from.list.indexOf(to.layer) + 1, 0, from.layer);
  });
  dragLayer = null;
});
document.addEventListener("dragover", (event) => {
  event.preventDefault();
  if (event.dataTransfer.types.includes("Files"))
    $("#viewport").classList.add("dragover");
});
document.addEventListener("dragleave", (event) => {
  if (!event.relatedTarget) $("#viewport").classList.remove("dragover");
});
document.addEventListener("drop", (event) => {
  event.preventDefault();
  $("#viewport").classList.remove("dragover");
  const file = event.dataTransfer.files[0];
  if (file) safe(async () => openData(await desktop.readDrop(file)));
});
let pointer = null;
$("#preview").addEventListener("pointerdown", (event) => {
  if (event.button !== 0 || event.altKey) return;
  const l = selection();
  if (l?.kind !== "text") return;
  checkpoint();
  pointer = { id: l.id };
  event.target.setPointerCapture(event.pointerId);
});
$("#preview").addEventListener("pointermove", (event) => {
  if (!pointer) return;
  const l = locate(project.snapshot.layers, pointer.id)?.layer;
  if (!l) return;
  const r = event.target.getBoundingClientRect(),
    snap = (v) =>
      Math.abs(v - 0.5) < 0.015 ? 0.5 : Math.max(0, Math.min(1, v));
  l.position = {
    x: snap((event.clientX - r.left) / r.width),
    y: snap((event.clientY - r.top) / r.height),
  };
  scheduleRender();
});
$("#preview").addEventListener("pointerup", () => {
  if (pointer) {
    pointer = null;
    update();
  }
});
new ResizeObserver(fitCanvas).observe($("#viewport"));
library();
update();
// Pure modules are tested independently; UI automation exercises the same public controls.

let pan = null;
$("#viewport").addEventListener("pointerdown", (event) => {
  if (event.button !== 1 && !event.altKey) return;
  event.preventDefault();
  const view = $("#viewport");
  pan = {
    x: event.clientX,
    y: event.clientY,
    left: view.scrollLeft,
    top: view.scrollTop,
  };
  view.setPointerCapture(event.pointerId);
});
$("#viewport").addEventListener("pointermove", (event) => {
  if (!pan) return;
  const view = $("#viewport");
  view.scrollLeft = pan.left + pan.x - event.clientX;
  view.scrollTop = pan.top + pan.y - event.clientY;
});
$("#viewport").addEventListener("pointerup", () => {
  pan = null;
});
