import Foundation
import AppKit

/// Sendable, Codable description of a text layer's content and styling.
/// Rendered to pixels by TextRenderer at whatever scale the caller needs
/// (preview scale for the canvas, full scale for export).
struct TextContent: Sendable, Codable, Hashable {
    var string: String
    var fontName: String            // PostScript name, e.g. "HelveticaNeue-Bold"
    var fontSize: Double            // points, in canvas space (unscaled)
    var color: RGBAColor
    var alignment: TextAlignmentValue
    var tracking: Double            // letter spacing, points
    var lineSpacing: Double         // extra leading, points
    /// Fixed box width in canvas points for wrapping; nil = auto-size to text.
    var boxWidth: Double?

    init(string: String = "Double-click to edit",
         fontName: String = "PingFangSC-Semibold",
         fontSize: Double = 64,
         color: RGBAColor = .white,
         alignment: TextAlignmentValue = .left,
         tracking: Double = 0,
         lineSpacing: Double = 0,
         boxWidth: Double? = nil) {
        self.string = string
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.alignment = alignment
        self.tracking = tracking
        self.lineSpacing = lineSpacing
        self.boxWidth = boxWidth
    }

    /// Resolve an NSFont for a given render scale. Falls back to system font
    /// if the named font is unavailable.
    func nsFont(scale: Double) -> NSFont {
        let size = fontSize * scale
        return NSFont(name: fontName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }
}
