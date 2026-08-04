# What's New in Filtered

A plain-language diary of how Filtered is growing — what got added, fixed,
and improved in each update. No tech jargon, just what you'll notice.

---

## Update 3 — Groups, Motion & a Smarter Darkroom *(August 4, 2026)*

The biggest update yet. Filtered now edits **moving pictures**, lets you
**organize layers into groups**, and gains a proper darkroom's worth of new
tools.

### Added
- **Two ways to work, made clear.** The right panel now has two modes:
  **Presets** — tap a look, tap another to swap it, done; and **Studio** —
  the full manual editor with layers and fine controls. Start simple, go
  deep when you want.
- **Layer groups.** Select several layers (⌘-click) and press ⌘G to fold
  them into a folder. Hide, fade, or blend the whole folder as one thing.
  ⇧⌘G dissolves it again. Great for treating a whole look as one unit.
- **Animated GIFs play here now.** Drop in a GIF and it comes alive on the
  canvas — press play, scrub through frames, and every filter you add
  applies to the motion. Export writes an animated GIF with all your edits
  baked into every frame. Projects saved as `.ftrd` keep the animation too.
- **Levels — edit the histogram itself.** A classic darkroom control: drag
  the black, midtone, and white markers right on the histogram to set
  contrast exactly where you want it.
- **Lightroom-style tools**: **Clarity** (midtone punch), **Dehaze** (cut
  through flat, milky light), and **Split Toning** (tint shadows and
  highlights different colors — the teal-and-orange movie look lives here).
- **ASCII art, for real this time** — actual characters, five styles
  (Classic, Blocks, @ Only, Binary, Random), with options for image colors,
  inverted brightness, and transparent backgrounds.
- **Eight more Looks**: Teal & Orange, Cinematic, Matte, Lomo, Sunburst,
  Arctic, Bleach Bypass, and Crisp Air — twenty in total now.
- The histogram panel can now show **RGB or brightness-only** views.

### Fixed
- **The layer hide (eye) button now works reliably** — clicks on the small
  buttons in layer cards were sometimes being captured by the card itself.
  This affected every layer type and is now fixed across the board.

### Improved
- Deleting works on the whole selection at once, and the Delete menu item
  understands multi-selection.
- New filters slot into a group automatically when you're working inside one.

---

## Update 2 — Pro Filters & a Smarter Auto Enhance *(August 4, 2026)*

### Added
- **14 new filters**, including White Balance (warm ↔ cool), Highlights /
  Shadows rescue, Vibrance, film styles (Sepia, Chrome, Fade, Instant,
  Noir, Tonal, Transfer), Noise Reduction, Motion Blur, Zoom Blur, and a
  playful Kaleidoscope.
- **A live histogram** in the image panel, so you can see exposure and
  clipping at a glance.
- **Four new Looks**: Golden Hour, Polaroid, Noir, and Faded Film.
- Press **⌘\\** to flip between your edit and the original.

### Fixed
- Starting a new canvas or opening a project now **asks before discarding
  unsaved work**.
- Typing new canvas dimensions can now be undone like any other edit.
- Duplicating a filter layer no longer tangles its settings with the
  original's undo history.

### Improved
- **Auto Enhance got smarter**: it now corrects color casts (too blue /
  too orange) and rescues crushed shadows and blown-out highlights — and
  everything it does is still just editable layers, never baked in.
- Filters are now organized with everyday adjustments first.

---

## Update 1 — First Release

Filtered is born: a fast, native Mac app for stacking filters like layers.

- 33 filters across halftone, pixelate, distort, stylize, glitch, and
  adjustment families — each one its own layer, affecting everything below.
- One-click **Looks** (Newsprint, Riso, VHS, Cyberpunk, and more), plus
  save-your-own.
- Text layers with every Mac font and imported fonts, with snap-to guides.
- Crop, rotate, flip, one-click subject cutout, Auto Enhance.
- Full undo/redo, zoom & pan, hold-to-compare, drag-and-drop import.
- Export to PNG / JPEG / TIFF / HEIC at up to 8K, with optional watermark
  and author metadata, and self-contained `.ftrd` project files.
