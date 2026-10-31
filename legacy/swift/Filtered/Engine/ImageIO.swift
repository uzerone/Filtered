import Foundation
import AppKit
import UniformTypeIdentifiers
import CoreImage
import ImageIO

/// Image import via NSOpenPanel and decode to a CIImage at native resolution.
/// Animated GIF/APNG files decode to full frame lists so the whole filter
/// pipeline can play and export them in motion.
enum ImageImporter {
    @MainActor
    static func importFromPanel(into document: FilteredDocument) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp, .webP, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url: url, into: document)
    }

    @MainActor
    @discardableResult
    static func importFile(url: URL, into document: FilteredDocument) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return importData(data, into: document)
    }

    /// Import raw image bytes (file, clipboard, drag & drop). Detects animated
    /// sources and installs all frames.
    @MainActor
    @discardableResult
    static func importData(_ data: Data, into document: FilteredDocument) -> Bool {
        if let animated = loadAnimatedFrames(data: data) {
            document.setAnimatedSource(frames: animated.frames, data: data,
                                       pixelSize: animated.size)
            return true
        }
        // applyOrientationProperty bakes the EXIF orientation into the image so
        // phone photos load upright instead of sideways.
        guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true])
        else { return false }
        document.setSourceImage(ci, pixelSize: Size2D(width: ci.extent.width,
                                                      height: ci.extent.height))
        return true
    }

    /// Import from the general pasteboard: copied image files first, then
    /// raw image data (e.g. a screenshot or an image copied from a browser).
    @MainActor
    @discardableResult
    static func importFromPasteboard(into document: FilteredDocument) -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]) as? [URL], let url = urls.first {
            return importFile(url: url, into: document)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type) {
                return importData(data, into: document)
            }
        }
        return false
    }

    // MARK: Animated decode

    /// Decode a multi-frame image (GIF/APNG/animated WebP). Returns nil for
    /// static images so callers fall through to the still path.
    static func loadAnimatedFrames(data: Data) -> (frames: [AnimationFrame], size: Size2D)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return nil }
        var frames: [AnimationFrame] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(AnimationFrame(image: CIImage(cgImage: cg),
                                         delay: frameDelay(src, index: i)))
        }
        guard let first = frames.first, frames.count > 1 else { return nil }
        return (frames, Size2D(width: first.image.extent.width,
                               height: first.image.extent.height))
    }

    private static func frameDelay(_ src: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil)
                as? [CFString: Any] else { return 0.1 }
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let d = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, d > 0.001 { return d }
            if let d = gif[kCGImagePropertyGIFDelayTime] as? Double, d > 0.001 { return d }
        }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let d = png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double, d > 0.001 { return d }
            if let d = png[kCGImagePropertyAPNGDelayTime] as? Double, d > 0.001 { return d }
        }
        if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            if let d = webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double, d > 0.001 { return d }
            if let d = webp[kCGImagePropertyWebPDelayTime] as? Double, d > 0.001 { return d }
        }
        return 0.1
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case png, jpeg, tiff, heic, gif
    var id: String { rawValue }
    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .heic: return UTType("public.heic") ?? .heic
        case .gif: return .gif
        }
    }
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .heic: return "heic"
        case .gif: return "gif"
        }
    }
    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
        case .gif: return "GIF"
        }
    }
    var supportsTransparency: Bool { self == .png || self == .tiff || self == .gif }
    var isLossy: Bool { self == .jpeg || self == .heic }
}

/// How the output resolution is decided.
enum ExportSizeMode: Equatable {
    case scale(Double)          // multiple of canvas size (1×, 2×, 3×…)
    case custom(width: Int, height: Int)   // explicit pixel dimensions
}

struct ExportOptions {
    var format: ExportFormat = .png
    var quality: Double = 0.9   // for lossy formats
    var sizeMode: ExportSizeMode = .scale(1)
    /// Write name.png / name@2x.png / name@3x.png in one go (scale mode only).
    var batchScales: Bool = false

    /// Resolve the effective renderScale given the canvas pixel size.
    func renderScale(canvasWidth: Int, canvasHeight: Int) -> Double {
        switch sizeMode {
        case .scale(let s): return s
        case .custom(let w, _):
            return canvasWidth > 0 ? Double(w) / Double(canvasWidth) : 1
        }
    }

    func outputSize(canvasWidth: Int, canvasHeight: Int) -> (Int, Int) {
        switch sizeMode {
        case .scale(let s):
            return (Int(Double(canvasWidth) * s), Int(Double(canvasHeight) * s))
        case .custom(let w, let h):
            return (w, h)
        }
    }
}

/// Flattens the document at FULL resolution through the SAME render pipeline as
/// preview, then writes the chosen format at the chosen size.
enum ImageExporter {
    @MainActor
    static func exportPanel(document: FilteredDocument, options: ExportOptions) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.format.utType]
        panel.nameFieldStringValue = "Filtered.\(options.format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Animated export: every frame runs through the full filter pipeline.
        if options.format == .gif, document.isAnimated {
            if !(await exportAnimatedGIF(document: document, to: url, options: options)) {
                presentError("Export failed", "The animation could not be written.")
            }
            return
        }

        // Batch mode: one pick, three files (name, name@2x, name@3x).
        if options.batchScales {
            let settings = AppSettings.shared
            let author = settings.embedAuthorMetadata ? settings.authorCredit : nil
            let base = url.deletingPathExtension()
            let ext = url.pathExtension
            for (scale, suffix) in [(1.0, ""), (2.0, "@2x"), (3.0, "@3x")] {
                let request = document.makeRenderRequest(renderScale: scale)
                guard var cg = await RenderEngine.shared.render(request)?.cgImage else { continue }
                if settings.addWatermark {
                    var text = settings.watermarkText.isEmpty ? settings.authorCredit : settings.watermarkText
                    if text.isEmpty { text = "Filtered" }
                    if let stamped = drawWatermark(text, on: cg) { cg = stamped }
                }
                let target = URL(fileURLWithPath: base.path + suffix).appendingPathExtension(ext)
                if !write(cgImage: cg, to: target, options: options, author: author) {
                    presentError("Export failed", "Couldn't write \(target.lastPathComponent).")
                    return
                }
            }
            return
        }

        let scale = options.renderScale(canvasWidth: document.canvas.width,
                                        canvasHeight: document.canvas.height)
        // Build the full-res request on the main actor (snapshots non-Sendable state).
        let request = document.makeRenderRequest(renderScale: scale)
        let result = await RenderEngine.shared.render(request)
        guard var cg = result?.cgImage else {
            presentError("Export failed", "The image could not be rendered.")
            return
        }
        // The render pipeline is uniform-scale only (pixel-space filter params
        // multiply by renderScale). If the user chose free-ratio custom
        // dimensions, resample the rendered image to the exact W×H now.
        let (targetW, targetH) = options.outputSize(canvasWidth: document.canvas.width,
                                                    canvasHeight: document.canvas.height)
        if targetW > 0, targetH > 0, (cg.width != targetW || cg.height != targetH) {
            if let resized = resample(cg, to: targetW, height: targetH) { cg = resized }
        }
        // Optional author watermark, drawn at full resolution.
        let settings = AppSettings.shared
        if settings.addWatermark {
            var text = settings.watermarkText.isEmpty ? settings.authorCredit : settings.watermarkText
            if text.isEmpty { text = "Filtered" }   // matches the Settings placeholder
            if let stamped = drawWatermark(text, on: cg) { cg = stamped }
        }
        if !write(cgImage: cg, to: url, options: options,
                  author: settings.embedAuthorMetadata ? settings.authorCredit : nil) {
            presentError("Export failed", "The file could not be written to \(url.lastPathComponent).")
        }
    }

    /// Render every animation frame through the full pipeline and write an
    /// animated GIF (infinite loop, original frame timings).
    @MainActor
    private static func exportAnimatedGIF(document: FilteredDocument, to url: URL,
                                          options: ExportOptions) async -> Bool {
        guard let frames = document.animationFrames, frames.count > 1 else { return false }
        let scale = options.renderScale(canvasWidth: document.canvas.width,
                                        canvasHeight: document.canvas.height)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return false }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let settings = AppSettings.shared
        var watermark: String? = nil
        if settings.addWatermark {
            let text = settings.watermarkText.isEmpty ? settings.authorCredit : settings.watermarkText
            watermark = text.isEmpty ? "Filtered" : text
        }

        for frame in frames {
            let request = document.makeRenderRequest(renderScale: scale,
                                                     baseOverride: frame.image)
            guard var cg = await RenderEngine.shared.render(request)?.cgImage else { return false }
            if let watermark, let stamped = drawWatermark(watermark, on: cg) { cg = stamped }
            CGImageDestinationAddImage(dest, cg, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frame.delay,
                    kCGImagePropertyGIFUnclampedDelayTime: frame.delay,
                ],
            ] as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
    }

    /// Stretch-resample to exact pixel dimensions (free-ratio custom export).
    private static func resample(_ cg: CGImage, to width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    @MainActor
    private static func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @discardableResult
    static func write(cgImage: CGImage, to url: URL, options: ExportOptions, author: String? = nil) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, options.format.utType.identifier as CFString, 1, nil) else { return false }
        var props: [CFString: Any] = [:]
        if options.format.isLossy {
            props[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        // Embed author + app into IPTC/TIFF metadata.
        if let author, !author.isEmpty {
            props[kCGImagePropertyIPTCDictionary] = [
                kCGImagePropertyIPTCByline: author,
                kCGImagePropertyIPTCCredit: author,
                kCGImagePropertyIPTCOriginatingProgram: "Filtered by @uzerone",
            ] as [CFString: Any]
            props[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFArtist: author,
                kCGImagePropertyTIFFSoftware: "Filtered",
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Draws a small semi-transparent watermark in the bottom-right corner.
    private static func drawWatermark(_ text: String, on cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx

        let fontSize = CGFloat(h) * 0.022
        let font = NSFont.systemFont(ofSize: max(fontSize, 12), weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = fontSize * 0.3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .shadow: shadow,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        let margin = CGFloat(w) * 0.02
        s.draw(at: CGPoint(x: CGFloat(w) - size.width - margin, y: margin), withAttributes: attrs)

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
