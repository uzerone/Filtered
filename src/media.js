import { parseGIF, decompressFrames } from "gifuct-js";
import gifenc from "gifenc";
import { surface, render } from "./engine.js";
const { GIFEncoder, quantize, applyPalette } = gifenc;
export const fromBase64 = (base64) =>
  Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
export async function loadImage(base64) {
  const img = new Image();
  img.src = `data:image/png;base64,${base64}`;
  await img.decode();
  const c = surface(img.width, img.height);
  c.getContext("2d").drawImage(img, 0, 0);
  return c;
}
export function decodeAnimation(base64) {
  const gif = parseGIF(fromBase64(base64)),
    w = gif.lsd.width,
    h = gif.lsd.height;
  if (!w || !h || w * h * gif.frames.length > 160000000)
    throw new Error(
      "Animation is too large to edit (160 million decoded pixels maximum).",
    );
  const raw = decompressFrames(gif, true);
  const canvas = surface(w, h),
    ctx = canvas.getContext("2d"),
    frames = [];
  let previous;
  for (const frame of raw) {
    if (frame.disposalType === 3) previous = ctx.getImageData(0, 0, w, h);
    const patch = surface(frame.dims.width, frame.dims.height);
    patch
      .getContext("2d")
      .putImageData(
        new ImageData(frame.patch, frame.dims.width, frame.dims.height),
        0,
        0,
      );
    ctx.drawImage(patch, frame.dims.left, frame.dims.top);
    const output = surface(w, h);
    output.getContext("2d").drawImage(canvas, 0, 0);
    frames.push({ image: output, delay: Math.max(20, frame.delay || 100) });
    if (frame.disposalType === 2)
      ctx.clearRect(
        frame.dims.left,
        frame.dims.top,
        frame.dims.width,
        frame.dims.height,
      );
    if (frame.disposalType === 3 && previous) ctx.putImageData(previous, 0, 0);
  }
  return frames;
}
export async function encodeGIF(
  project,
  frames,
  maxSize,
  onProgress = () => {},
) {
  const encoder = GIFEncoder();
  for (let i = 0; i < frames.length; i++) {
    const canvas = render(project, frames[i].image, { maxSize }),
      rgba = canvas
        .getContext("2d")
        .getImageData(0, 0, canvas.width, canvas.height).data;
    const palette = quantize(rgba, 256, {
        format: "rgba4444",
        oneBitAlpha: true,
      }),
      indexed = applyPalette(rgba, palette, "rgba4444"),
      transparentIndex = palette.findIndex((c) => c[3] === 0);
    encoder.writeFrame(indexed, canvas.width, canvas.height, {
      palette,
      delay: frames[i].delay,
      repeat: 0,
      transparent: transparentIndex >= 0,
      transparentIndex: Math.max(0, transparentIndex),
      dispose: 2,
    });
    onProgress(i + 1, frames.length);
    await new Promise((r) => setTimeout(r, 0));
  }
  encoder.finish();
  return encoder.bytes();
}
export async function pngBytes(canvas) {
  return new Uint8Array(
    await (
      await new Promise((resolve) => canvas.toBlob(resolve, "image/png"))
    ).arrayBuffer(),
  );
}
