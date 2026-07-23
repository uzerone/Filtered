import Foundation
import AppKit
import UniformTypeIdentifiers
import CoreImage
import ImageIO

/// Image import via NSOpenPanel and decode to a CIImage at native resolution.
enum ImageImporter {
    @MainActor
    static func openPanel() -> (CIImage, Size2D)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return load(url: url)
    }

    static func load(url: URL) -> (CIImage, Size2D)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        let size = Size2D(width: Double(cg.width), height: Double(cg.height))
        return (ci, size)
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case png, jpeg, tiff, heic
    var id: String { rawValue }
    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .heic: return UTType("public.heic") ?? .heic
        }
    }
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .heic: return "heic"
        }
    }
    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
        }
    }
    var supportsTransparency: Bool { self == .png || self == .tiff }
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

        let scale = options.renderScale(canvasWidth: document.canvas.width,
                                        canvasHeight: document.canvas.height)
        // Build the full-res request on the main actor (snapshots non-Sendable state).
        let request = document.makeRenderRequest(renderScale: scale)
        let result = await RenderEngine.shared.render(request)
        guard var cg = result?.cgImage else {
            NSSound.beep(); return
        }
        // Optional author watermark, drawn at full resolution.
        let settings = AppSettings.shared
        if settings.addWatermark {
            let text = settings.watermarkText.isEmpty ? settings.authorCredit : settings.watermarkText
            if !text.isEmpty, let stamped = drawWatermark(text, on: cg) { cg = stamped }
        }
        write(cgImage: cg, to: url, options: options,
              author: settings.embedAuthorMetadata ? settings.authorCredit : nil)
    }

    static func write(cgImage: CGImage, to url: URL, options: ExportOptions, author: String? = nil) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, options.format.utType.identifier as CFString, 1, nil) else { return }
        var props: [CFString: Any] = [:]
        if options.format.isLossy {
            props[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        // Embed author + app into IPTC/TIFF metadata.
        if let author, !author.isEmpty {
            props[kCGImagePropertyIPTCDictionary] = [
                kCGImagePropertyIPTCByline: author,
                kCGImagePropertyIPTCCredit: author,
                kCGImagePropertyIPTCOriginatingProgram: "Filtered by JYEU@CTRLP",
            ] as [CFString: Any]
            props[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFArtist: author,
                kCGImagePropertyTIFFSoftware: "Filtered",
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        CGImageDestinationFinalize(dest)
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
