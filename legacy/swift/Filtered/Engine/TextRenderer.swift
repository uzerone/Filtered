import Foundation
import AppKit
import CoreImage

/// Rasterizes a TextContent into a CIImage at a given render scale.
///
/// Correctness rules (from design review):
///  - fontSize, tracking, lineSpacing, and box width are all multiplied by
///    `scale` so preview (scale≈backing/fit) and export (scale=full/canvas)
///    are pixel-identical in layout, just at different resolutions.
///  - The SAME wrap width is used regardless of the layer's on-canvas position,
///    so dragging a text layer never re-wraps it.
///  - Draws into a premultiplied bitmap; the resulting CIImage already carries
///    the correct alpha (no post-hoc CIColorMatrix opacity hacks).
enum TextRenderer {

    /// Measured, unscaled size of the text in canvas points (for auto-size boxes
    /// and hit-testing). Runs on the main actor because it touches NSAttributedString layout.
    @MainActor
    static func measure(_ content: TextContent) -> CGSize {
        let attr = attributedString(content, scale: 1)
        let maxWidth = content.boxWidth.map { CGFloat($0) } ?? .greatestFiniteMagnitude
        let bounds = attr.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// Render to a CIImage whose extent origin is (0,0). The caller positions it.
    @MainActor
    static func render(_ content: TextContent, scale: Double) -> CIImage? {
        let attr = attributedString(content, scale: scale)

        // Determine layout box in *scaled* pixels.
        let wrapWidth: CGFloat = content.boxWidth.map { CGFloat($0 * scale) } ?? .greatestFiniteMagnitude
        let bounds = attr.boundingRect(
            with: CGSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let pxWidth = max(1, Int(ceil(bounds.width)))
        let pxHeight = max(1, Int(ceil(bounds.height)))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxWidth,
            pixelsHigh: pxHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))

        let drawRect = CGRect(x: 0, y: 0, width: CGFloat(pxWidth), height: CGFloat(pxHeight))
        attr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        NSGraphicsContext.restoreGraphicsState()

        guard let cg = rep.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    @MainActor
    private static func attributedString(_ content: TextContent, scale: Double) -> NSAttributedString {
        let font = content.nsFont(scale: scale)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = content.alignment.nsTextAlignment
        paragraph.lineSpacing = CGFloat(content.lineSpacing * scale)

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: content.color.nsColor,
            .paragraphStyle: paragraph,
        ]
        if content.tracking != 0 {
            attrs[.kern] = CGFloat(content.tracking * scale)
        }
        return NSAttributedString(string: content.string, attributes: attrs)
    }
}
