# Filtered 2.0

A desktop image and GIF editor built with Electron. Add filters, text, and watermarks, then save or export your work.

## Features

- 51 filters and 20 presets, plus custom Looks.
- Editable layers with groups, opacity, and blend modes.
- Text tools, crop, rotate, flip, and Auto Enhance.
- Watermarks with five presets, editable text, styling, and positioning.
- Animated GIF playback, editing, and export.
- Portable `.ftrd` projects, including files from the Swift version.
- PNG, JPEG, WebP, TIFF, GIF, and macOS HEIC export.

## Run

Requires Node.js 22+ and npm. Building on macOS also requires Xcode Command Line Tools.

```sh
npm install
npm start
```

## Build and test

```sh
npm test
npm run test:smoke
npm run package
```

macOS packaging requires Xcode 26+ for native light/dark icon assets.

The packaged app is saved in `release/`. Use `npm run dist` to create an installer.

## Notes

Tested on Apple Silicon macOS. Windows and Linux builds are configured but untested. Subject cutout requires macOS 14+ and a still image.

Version 2.0 replaces Swift with Electron. Some effects look different from the original. The Swift source is preserved in `legacy/swift/`.

[Changelog](DEVELOPMENT.md) · [MIT License](LICENSE)
