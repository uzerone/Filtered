import { layer } from "./model.js";
export const watermarkPresets = [
  {
    id: "corner",
    name: "Subtle corner",
    anchor: "bottom-right",
    opacity: 0.6,
    size: 0.035,
    font: "Arial",
    rotation: 0,
    repeat: false,
  },
  {
    id: "signature",
    name: "Signature",
    anchor: "bottom-left",
    opacity: 0.85,
    size: 0.055,
    font: "Georgia",
    rotation: 0,
    repeat: false,
  },
  {
    id: "center",
    name: "Centered",
    anchor: "center",
    opacity: 0.3,
    size: 0.085,
    font: "Arial",
    rotation: 0,
    repeat: false,
  },
  {
    id: "diagonal",
    name: "Diagonal",
    anchor: "center",
    opacity: 0.25,
    size: 0.09,
    font: "Arial",
    rotation: -Math.PI / 6,
    repeat: false,
  },
  {
    id: "tiled",
    name: "Tiled",
    anchor: "center",
    opacity: 0.2,
    size: 0.035,
    font: "Arial",
    rotation: -Math.PI / 6,
    repeat: true,
  },
];
export const watermarkPositions = [
  ["top-left", "Top left", "↖"],
  ["top", "Top", "↑"],
  ["top-right", "Top right", "↗"],
  ["left", "Left", "←"],
  ["center", "Center", "•"],
  ["right", "Right", "→"],
  ["bottom-left", "Bottom left", "↙"],
  ["bottom", "Bottom", "↓"],
  ["bottom-right", "Bottom right", "↘"],
];
export function positionWatermark(item, anchor) {
  if (!watermarkPositions.some((p) => p[0] === anchor))
    throw new Error("Invalid watermark position.");
  item.watermark.anchor = anchor;
  item.position = {
    x: anchor.includes("left") ? 0.04 : anchor.includes("right") ? 0.96 : 0.5,
    y: anchor.includes("top") ? 0.04 : anchor.includes("bottom") ? 0.96 : 0.5,
  };
  item.text.alignment = anchor.includes("left")
    ? "left"
    : anchor.includes("right")
      ? "right"
      : "center";
}
export function applyWatermarkPreset(item, id, canvas) {
  const preset = watermarkPresets.find((p) => p.id === id);
  if (!preset) throw new Error("Unknown watermark preset.");
  item.watermark = {
    preset: id,
    repeat: preset.repeat,
    spacing: 0.35,
    anchor: preset.anchor,
  };
  item.opacity = preset.opacity;
  item.rotation = preset.rotation;
  Object.assign(item.text, {
    fontName: preset.font,
    fontSize: Math.max(4, Math.min(canvas.width, canvas.height) * preset.size),
    color: { r: 1, g: 1, b: 1, a: 1 },
    tracking: 0,
    lineSpacing: 0,
    boxWidth: null,
  });
  positionWatermark(item, preset.anchor);
  return item;
}
export function createWatermark(
  canvas,
  text = "© Your name",
  preset = "corner",
) {
  return applyWatermarkPreset(
    layer("text", { name: "Watermark", text: { string: text } }),
    preset,
    canvas,
  );
}
