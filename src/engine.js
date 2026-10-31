import { byId } from "./catalog.js";
import { valuesOf } from "./model.js";
export function surface(w, h) {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  return c;
}
export function copy(source) {
  const c = surface(source.width, source.height);
  c.getContext("2d").drawImage(source, 0, 0);
  return c;
}
export const cssColor = (c = { r: 0, g: 0, b: 0, a: 1 }) =>
  `rgba(${c.r * 255},${c.g * 255},${c.b * 255},${c.a ?? 1})`;
const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
const mix = (a, b, t) => a + (b - a) * t;
const luma = (r, g, b) => r * 0.2126 + g * 0.7152 + b * 0.0722;
const noise = (x, y, seed = 1) => {
  const n = Math.sin(x * 12.9898 + y * 78.233 + seed * 37.719) * 43758.5453;
  return n - Math.floor(n);
};
function pixels(c, fn) {
  const ctx = c.getContext("2d", { willReadFrequently: true }),
    im = ctx.getImageData(0, 0, c.width, c.height);
  fn(im.data, c.width, c.height);
  ctx.putImageData(im, 0, 0);
  return c;
}
function cssFilter(source, filter) {
  const out = surface(source.width, source.height),
    ctx = out.getContext("2d");
  ctx.filter = filter;
  ctx.drawImage(source, 0, 0);
  return out;
}
function remap(source, mapping) {
  const out = copy(source),
    src = source
      .getContext("2d")
      .getImageData(0, 0, source.width, source.height).data;
  return pixels(out, (d, w, h) => {
    for (let y = 0; y < h; y++)
      for (let x = 0; x < w; x++) {
        const [sx, sy] = mapping(x, y, w, h),
          i = (y * w + x) * 4,
          j =
            (clamp(Math.round(sy), 0, h - 1) * w +
              clamp(Math.round(sx), 0, w - 1)) *
            4;
        for (let k = 0; k < 4; k++) d[i + k] = src[j + k];
      }
  });
}
export function applyFilter(source, filter, scale = 1) {
  const kind = filter.kind,
    p = valuesOf(filter),
    w = source.width,
    h = source.height;
  for (const spec of byId[kind].params)
    if (spec.kind === "pixelScalar") p[spec.key] *= scale;
  const center = p.inputCenter;
  const cx = center?.x ? center.x * scale : w / 2,
    cy = center?.y ? h - center.y * scale : h / 2;
  if (kind === "blur") return cssFilter(source, `blur(${p.inputRadius}px)`);
  if (kind === "hue")
    return cssFilter(source, `hue-rotate(${p.inputAngle}rad)`);
  if (
    [
      "bloom",
      "clarity",
      "unsharpMask",
      "sharpenLuminance",
      "noiseReduction",
    ].includes(kind)
  ) {
    const radius =
      kind === "clarity"
        ? 16 * scale
        : kind === "noiseReduction"
          ? Math.max(0.2, p.inputNoiseLevel * 100 * scale)
          : (p.inputRadius ?? 2 * scale);
    const blurred = cssFilter(source, `blur(${radius}px)`),
      b = blurred.getContext("2d").getImageData(0, 0, w, h).data;
    return pixels(copy(source), (d) => {
      for (let i = 0; i < d.length; i += 4)
        for (let k = 0; k < 3; k++) {
          if (kind === "bloom")
            d[i + k] =
              255 -
              (255 - d[i + k]) *
                (1 - (b[i + k] / 255) * clamp(p.inputIntensity / 2));
          else if (kind === "noiseReduction")
            d[i + k] =
              mix(d[i + k], b[i + k], clamp(p.inputNoiseLevel * 8)) +
              (d[i + k] - b[i + k]) * p.inputSharpness * 0.15;
          else
            d[i + k] +=
              (d[i + k] - b[i + k]) *
              (p.amount ?? p.inputIntensity ?? p.inputSharpness);
        }
    });
  }
  if (["motionBlur", "zoomBlur"].includes(kind)) {
    const out = surface(w, h),
      ctx = out.getContext("2d"),
      steps = 20,
      amount = p.inputRadius ?? p.inputAmount;
    ctx.globalAlpha = 1 / steps;
    ctx.globalCompositeOperation = "lighter";
    for (let i = 0; i < steps; i++) {
      const t = i / (steps - 1) - 0.5;
      ctx.save();
      if (kind === "motionBlur")
        ctx.translate(
          Math.cos(p.inputAngle) * t * amount,
          Math.sin(p.inputAngle) * t * amount,
        );
      else {
        ctx.translate(cx, cy);
        ctx.scale(1 + (t * amount) / 200, 1 + (t * amount) / 200);
        ctx.translate(-cx, -cy);
      }
      ctx.drawImage(source, 0, 0);
      ctx.restore();
    }
    return out;
  }
  if (
    [
      "twirl",
      "bump",
      "glass",
      "kaleidoscope",
      "glitch",
      "mosaicTiles",
      "crystallize",
    ].includes(kind)
  )
    return remap(source, (x, y) => {
      let dx = x - cx,
        dy = y - cy,
        r = Math.hypot(dx, dy),
        a = Math.atan2(dy, dx);
      if (kind === "twirl") {
        a += p.inputAngle * Math.max(0, 1 - r / p.inputRadius);
        return [cx + Math.cos(a) * r, cy + Math.sin(a) * r];
      }
      if (kind === "bump") {
        const f = 1 - p.inputScale * Math.max(0, 1 - r / p.inputRadius) ** 2;
        return [cx + dx * f, cy + dy * f];
      }
      if (kind === "glass")
        return [
          x + Math.sin(y / (13 * scale)) * p.inputScale * 0.12,
          y + Math.cos(x / (17 * scale)) * p.inputScale * 0.12,
        ];
      if (kind === "kaleidoscope") {
        const wedge = (Math.PI * 2) / Math.round(p.inputCount);
        a = (((a + p.inputAngle) % wedge) + wedge) % wedge;
        a = Math.min(a, wedge - a);
        return [cx + Math.cos(a) * r, cy + Math.sin(a) * r];
      }
      if (kind === "glitch") {
        const row = Math.floor(y / Math.max(1, p.sliceHeight)),
          offset =
            noise(row, 0, p.seed) > 0.65
              ? (noise(row, 1, p.seed) - 0.5) * w * p.amount
              : 0;
        return [(x + offset + w) % w, y];
      }
      const size = Math.max(
        1,
        kind === "mosaicTiles" ? p.inputScale : p.inputRadius,
      );
      const row = Math.floor((y - cy) / size),
        col = Math.floor((x - cx + ((row % 2) * size) / 2) / size);
      return [
        cx + col * size - ((row % 2) * size) / 2 + size / 2,
        cy + row * size + size / 2,
      ];
    });
  if (kind === "chromaticAberration") {
    const out = copy(source),
      src = source.getContext("2d").getImageData(0, 0, w, h).data,
      dx = Math.round(Math.cos(p.angle) * p.amount),
      dy = Math.round(Math.sin(p.angle) * p.amount);
    return pixels(out, (d) => {
      for (let y = 0; y < h; y++)
        for (let x = 0; x < w; x++) {
          let i = (y * w + x) * 4;
          d[i] =
            src[(clamp(y + dy, 0, h - 1) * w + clamp(x + dx, 0, w - 1)) * 4];
          d[i + 2] =
            src[
              (clamp(y - dy, 0, h - 1) * w + clamp(x - dx, 0, w - 1)) * 4 + 2
            ];
        }
    });
  }
  if (["halftoneCircle", "halftoneDots", "colorHalftone"].includes(kind)) {
    const src = source.getContext("2d").getImageData(0, 0, w, h).data;
    const pitch = Math.max(1, p.inputWidth);
    const softness = Math.max(0.4, (1 - p.inputSharpness) * pitch * 0.45);
    const coverage = (x, y, angle, channel) => {
      const cos = Math.cos(angle),
        sin = Math.sin(angle);
      const u = (x - cx) * cos + (y - cy) * sin;
      const v = -(x - cx) * sin + (y - cy) * cos;
      const gu = Math.floor(u / pitch) * pitch + pitch / 2;
      const gv = Math.floor(v / pitch) * pitch + pitch / 2;
      const sx = clamp(Math.round(cx + gu * cos - gv * sin), 0, w - 1);
      const sy = clamp(Math.round(cy + gu * sin + gv * cos), 0, h - 1);
      const i = (sy * w + sx) * 4;
      const black = 1 - Math.max(src[i], src[i + 1], src[i + 2]) / 255;
      let ink = 1 - luma(src[i], src[i + 1], src[i + 2]) / 255;
      if (channel === 3) ink = black * p.inputGCR;
      else if (channel >= 0)
        ink = clamp(
          1 - src[i + channel] / 255 - black * p.inputGCR * p.inputUCR,
        );
      const radius = Math.sqrt(ink) * pitch * 0.707;
      return clamp((radius - Math.hypot(u - gu, v - gv)) / softness + 0.5);
    };
    return pixels(copy(source), (d) => {
      for (let y = 0; y < h; y++)
        for (let x = 0; x < w; x++) {
          const i = (y * w + x) * 4;
          if (kind === "colorHalftone") {
            const black = coverage(x, y, p.inputAngle + Math.PI / 4, 3);
            for (let k = 0; k < 3; k++)
              d[i + k] =
                255 *
                (1 - coverage(x, y, p.inputAngle + (k * Math.PI) / 6, k)) *
                (1 - black);
          } else {
            const gray = 255 * (1 - coverage(x, y, p.inputAngle ?? 0, -1));
            d[i] = d[i + 1] = d[i + 2] = gray;
          }
        }
    });
  }
  if (["mosaic", "pointillize", "ascii"].includes(kind)) {
    const size = Math.max(
        2,
        p.cellSize ?? p.inputScale ?? p.inputWidth ?? p.inputRadius * 2,
      ),
      out = surface(w, h),
      ctx = out.getContext("2d"),
      src = source.getContext("2d").getImageData(0, 0, w, h).data;
    if (kind === "ascii" && !p.transparentBG) {
      ctx.fillStyle = p.inverted ? "white" : "black";
      ctx.fillRect(0, 0, w, h);
    }
    ctx.font = `${size}px monospace`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    const startX = kind === "ascii" ? 0 : (((cx % size) + size) % size) - size;
    const startY = kind === "ascii" ? 0 : (((cy % size) + size) % size) - size;
    for (let y = startY; y < h; y += size)
      for (let x = startX; x < w; x += size) {
        const i =
            (clamp(Math.floor(y + size / 2), 0, h - 1) * w +
              clamp(Math.floor(x + size / 2), 0, w - 1)) *
            4,
          r = src[i],
          g = src[i + 1],
          b = src[i + 2],
          a = src[i + 3] / 255,
          lum = luma(r, g, b) / 255;
        ctx.fillStyle = `rgba(${r},${g},${b},${a})`;
        if (kind === "mosaic") ctx.fillRect(x, y, size, size);
        else if (kind === "ascii") {
          const sets = [" .:-=+*#%@", " ░▒▓█", " @", "01", " .+*#@%&"];
          let n = p.inverted ? 1 - lum : lum,
            chars = sets[Math.round(p.style)];
          ctx.fillStyle = p.colored
            ? `rgba(${r},${g},${b},${a})`
            : p.inverted
              ? "black"
              : "white";
          let ch =
            chars[
              Math.min(
                chars.length - 1,
                Math.floor(
                  (p.style === 4 ? noise(x, y) * n : n) * chars.length,
                ),
              )
            ];
          ctx.fillText(ch, x + size / 2, y + size / 2);
        } else {
          const radius = size * 0.45;
          ctx.beginPath();
          ctx.arc(x + size / 2, y + size / 2, radius, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    return out;
  }
  if (kind === "edges" || kind === "comic") {
    const src = source.getContext("2d").getImageData(0, 0, w, h).data;
    return pixels(copy(source), (d) => {
      for (let y = 0; y < h; y++)
        for (let x = 0; x < w; x++) {
          const i = (y * w + x) * 4,
            ri = (y * w + Math.min(w - 1, x + 1)) * 4,
            bi = (Math.min(h - 1, y + 1) * w + x) * 4;
          let e = 0;
          for (let k = 0; k < 3; k++)
            e +=
              Math.abs(src[i + k] - src[ri + k]) +
              Math.abs(src[i + k] - src[bi + k]);
          e = clamp((e / 3) * (p.inputIntensity ?? 2), 0, 255);
          for (let k = 0; k < 3; k++)
            d[i + k] =
              kind === "edges"
                ? e
                : Math.round(src[i + k] / 51) * 51 * (1 - e / 255);
        }
    });
  }
  if (kind === "pixelSort")
    return pixels(copy(source), (d, w, h) => {
      for (let y = 0; y < h; y++) {
        let start = 0;
        while (start < w) {
          while (
            start < w &&
            luma(...d.slice((y * w + start) * 4, (y * w + start) * 4 + 3)) /
              255 <
              p.threshold
          )
            start++;
          let end = start;
          while (
            end < w &&
            luma(...d.slice((y * w + end) * 4, (y * w + end) * 4 + 3)) / 255 >=
              p.threshold
          )
            end++;
          const len = Math.floor((end - start) * p.amount),
            row = [];
          for (let x = start; x < start + len; x++)
            row.push(Array.from(d.slice((y * w + x) * 4, (y * w + x) * 4 + 4)));
          row.sort((a, b) => luma(...a) - luma(...b));
          row.forEach((v, i) => d.set(v, (y * w + start + i) * 4));
          start = Math.max(end, start + 1);
        }
      }
    });
  return pixels(copy(source), (d, w, h) => {
    for (let i = 0; i < d.length; i += 4) {
      let r = d[i] / 255,
        g = d[i + 1] / 255,
        b = d[i + 2] / 255,
        lum = luma(r, g, b),
        x = (i / 4) % w,
        y = Math.floor(i / 4 / w);
      let rgb = [r, g, b];
      switch (kind) {
        case "colorControls":
          rgb = rgb.map(
            (v) =>
              (mix(lum, v, p.inputSaturation) - 0.5) * p.inputContrast +
              0.5 +
              p.inputBrightness,
          );
          break;
        case "exposure":
          rgb = rgb.map((v) => v * 2 ** p.inputEV);
          break;
        case "gamma":
          rgb = rgb.map((v) => v ** p.inputPower);
          break;
        case "levels":
          rgb = rgb.map((v) =>
            mix(
              p.outBlack,
              p.outWhite,
              clamp((v - p.inBlack) / Math.max(0.001, p.inWhite - p.inBlack)) **
                (1 / p.gamma),
            ),
          );
          break;
        case "curves":
          rgb = rgb.map((v) => {
            const q = clamp(v) * 4,
              j = Math.min(3, Math.floor(q));
            return mix(p[`y${j}`], p[`y${j + 1}`], q - j);
          });
          break;
        case "whiteBalance":
          rgb = [
            r + (p.temp - 6500) / 18000,
            g + p.tint / 1000,
            b - (p.temp - 6500) / 18000,
          ];
          break;
        case "highlightShadow":
          rgb = rgb.map(
            (v) =>
              v +
              p.inputShadowAmount * (1 - lum) ** 2 * 0.5 -
              (1 - p.inputHighlightAmount) * lum ** 2 * 0.5,
          );
          break;
        case "vibrance": {
          const sat = Math.max(...rgb) - Math.min(...rgb);
          rgb = rgb.map((v) => mix(lum, v, 1 + p.inputAmount * (1 - sat)));
          break;
        }
        case "dehaze":
          rgb = rgb.map(
            (v) =>
              clamp((v - 0.5) * (1 + p.amount * 0.6) + 0.5) **
              (1 + p.amount * 0.2),
          );
          break;
        case "threshold":
          rgb = rgb.map(() => (lum >= p.inputThreshold ? 1 : 0));
          break;
        case "posterize":
          rgb = rgb.map(
            (v) => Math.round(v * (p.inputLevels - 1)) / (p.inputLevels - 1),
          );
          break;
        case "invert":
          rgb = rgb.map((v) => 1 - v);
          break;
        case "grain":
          rgb = rgb.map((v) => v + (noise(x, y) - 0.5) * p.grainAmount);
          break;
        case "gradientMap":
          rgb = ["r", "g", "b"].map((k) =>
            mix(p.shadow[k], p.highlight[k], lum),
          );
          break;
        case "monochrome":
          rgb = rgb.map((v, k) =>
            mix(
              v,
              lum * (0.5 + p.inputColor[["r", "g", "b"][k]]),
              p.inputIntensity,
            ),
          );
          break;
        case "splitTone":
          rgb = rgb.map((v, k) =>
            mix(
              v,
              mix(
                p.shadowColor[["r", "g", "b"][k]],
                p.highlightColor[["r", "g", "b"][k]],
                lum,
              ) *
                lum *
                1.5,
              p.amount * 0.6,
            ),
          );
          break;
        case "sepia": {
          const s = [
            r * 0.393 + g * 0.769 + b * 0.189,
            r * 0.349 + g * 0.686 + b * 0.168,
            r * 0.272 + g * 0.534 + b * 0.131,
          ];
          rgb = rgb.map((v, k) => mix(v, s[k], p.inputIntensity));
          break;
        }
        case "filmNoir":
          rgb = rgb.map(() => clamp((lum - 0.5) * 1.5 + 0.5));
          break;
        case "filmTonal":
          rgb = rgb.map(() => lum * 0.9 + 0.04);
          break;
        case "filmChrome":
          rgb = rgb.map((v) => (mix(lum, v, 1.35) - 0.5) * 1.2 + 0.5);
          break;
        case "filmFade":
          rgb = rgb.map((v) => mix(lum, v, 0.7) * 0.8 + 0.12);
          break;
        case "filmInstant":
          rgb = [r * 0.9 + 0.12, g * 0.85 + 0.08, b * 0.7 + 0.12];
          break;
        case "filmTransfer":
          rgb = [r * 0.88 + 0.1, g * 0.82 + 0.09, b * 0.7 + 0.13];
          break;
        case "vignette": {
          const dist = Math.hypot((x - w / 2) / (w / 2), (y - h / 2) / (h / 2));
          const v =
            1 - clamp((dist - p.inputRadius * 0.25) * p.inputIntensity * 0.6);
          rgb = rgb.map((c) => c * v);
          break;
        }
        case "scanlines":
          if (
            y % Math.max(2, Math.round(p.spacing)) <
            Math.max(1, p.spacing / 3)
          )
            rgb = rgb.map((v) => v * (1 - p.intensity));
          break;
        default:
          throw new Error(`Filter not implemented: ${kind}`);
      }
      d[i] = clamp(rgb[0]) * 255;
      d[i + 1] = clamp(rgb[1]) * 255;
      d[i + 2] = clamp(rgb[2]) * 255;
    }
  });
}
function composite(base, top, layer) {
  const c = copy(base),
    ctx = c.getContext("2d");
  ctx.globalAlpha = layer.opacity;
  ctx.globalCompositeOperation =
    layer.blendMode === "softLight"
      ? "soft-light"
      : layer.blendMode === "normal" || !layer.blendMode
        ? "source-over"
        : layer.blendMode;
  ctx.drawImage(top, 0, 0);
  return c;
}
export function render(
  project,
  source,
  { maxSize = 1400, original = false } = {},
) {
  const c = project.snapshot.canvas,
    scale = Math.min(1, maxSize / Math.max(c.width, c.height)),
    w = Math.max(1, Math.round(c.width * scale)),
    h = Math.max(1, Math.round(c.height * scale));
  let base = surface(w, h),
    ctx = base.getContext("2d");
  if (c.background.solid) {
    ctx.fillStyle = cssColor(c.background.solid._0);
    ctx.fillRect(0, 0, w, h);
  }
  let image;
  if (source) {
    const q = (((c.orientationQuarters ?? 0) % 4) + 4) % 4,
      sw = source.width,
      sh = source.height,
      oriented = surface(q % 2 ? sh : sw, q % 2 ? sw : sh),
      oc = oriented.getContext("2d");
    oc.translate(oriented.width / 2, oriented.height / 2);
    oc.rotate((q * Math.PI) / 2);
    oc.scale(c.flippedH ? -1 : 1, 1);
    oc.drawImage(source, -sw / 2, -sh / 2);
    image = surface(w, h);
    const ic = image.getContext("2d"),
      sx = (c.cropX ?? 0) * oriented.width,
      sy = (1 - (c.cropY ?? 0) - (c.cropH ?? 1)) * oriented.height,
      cw = (c.cropW ?? 1) * oriented.width,
      ch = (c.cropH ?? 1) * oriented.height;
    let factor =
        c.imageFit === "fill"
          ? Math.max(w / cw, h / ch)
          : c.imageFit === "actual"
            ? scale
            : Math.min(w / cw, h / ch),
      dw = c.imageFit === "stretch" ? w : cw * factor,
      dh = c.imageFit === "stretch" ? h : ch * factor;
    ic.drawImage(oriented, sx, sy, cw, ch, (w - dw) / 2, (h - dh) / 2, dw, dh);
  }
  if (original && image) {
    ctx.drawImage(image, 0, 0);
    return base;
  }
  const stack = (layers, below) => {
    for (const l of layers) {
      if (!l.isVisible) continue;
      if (original && l.kind !== "image") continue;
      if (l.kind === "image" && image) below = composite(below, image, l);
      if (l.kind === "filter" && l.filter.isEnabled)
        below = composite(below, applyFilter(below, l.filter, scale), l);
      if (l.kind === "group")
        below = composite(below, stack(l.children ?? [], copy(below)), l);
      if (l.kind === "text") {
        const t = l.text,
          top = surface(w, h),
          tc = top.getContext("2d");
        tc.fillStyle = cssColor(t.color);
        tc.font = `${t.fontSize * scale}px "${t.fontName.replaceAll('"', "")}"`;
        tc.textBaseline = "middle";
        tc.textAlign = t.alignment;
        tc.letterSpacing = `${t.tracking * scale}px`;
        const lines = [];
        for (const paragraph of t.string.split("\n")) {
          if (!t.boxWidth) lines.push(paragraph);
          else {
            let line = "";
            for (const word of paragraph.split(" ")) {
              const next = line ? line + " " + word : word;
              if (tc.measureText(next).width > t.boxWidth * scale && line) {
                lines.push(line);
                line = word;
              } else line = next;
            }
            lines.push(line);
          }
        }
        const width = t.boxWidth
            ? t.boxWidth * scale
            : Math.max(...lines.map((s) => tc.measureText(s).width)),
          lineHeight = (t.fontSize * 1.2 + t.lineSpacing) * scale,
          tx = l.watermark
            ? 0
            : t.alignment === "left"
              ? -width / 2
              : t.alignment === "right"
                ? width / 2
                : 0;
        const vertical = l.watermark?.anchor?.includes("top")
          ? (lines.length * lineHeight) / 2
          : l.watermark?.anchor?.includes("bottom")
            ? (-lines.length * lineHeight) / 2
            : 0;
        const drawText = (x, y) => {
          tc.save();
          tc.translate(x, y);
          tc.rotate(l.rotation);
          lines.forEach((line, i) =>
            tc.fillText(
              line,
              tx,
              (i - (lines.length - 1) / 2) * lineHeight + vertical,
            ),
          );
          tc.restore();
        };
        if (l.watermark?.repeat) {
          const spacing = clamp(l.watermark.spacing ?? 0.35, 0.15, 0.75);
          const dx = w * spacing,
            dy = h * spacing;
          for (let y = ((l.position.y * h) % dy) - dy; y < h + dy; y += dy)
            for (let x = ((l.position.x * w) % dx) - dx; x < w + dx; x += dx)
              drawText(x, y);
        } else drawText(l.position.x * w, l.position.y * h);
        below = composite(below, top, l);
      }
    }
    return below;
  };
  return stack(project.snapshot.layers, base);
}
export function histogram(canvas) {
  const d = canvas
      .getContext("2d")
      .getImageData(0, 0, canvas.width, canvas.height).data,
    bins = Array.from({ length: 4 }, () => new Array(256).fill(0));
  for (let i = 0; i < d.length; i += 4) {
    if (!d[i + 3]) continue;
    for (let k = 0; k < 3; k++) bins[k][d[i + k]]++;
    bins[3][Math.round(luma(d[i], d[i + 1], d[i + 2]))]++;
  }
  return bins;
}
