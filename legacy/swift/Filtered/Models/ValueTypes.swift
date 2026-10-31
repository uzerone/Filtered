import Foundation
import CoreGraphics
import AppKit

// MARK: - Sendable value descriptors
// These are the ONLY types allowed to cross from the @MainActor UI/model layer
// into the off-actor render engine. They are plain Sendable + Codable values —
// never NSFont/NSColor/CIImage (which are not Sendable on this SDK).

/// RGBA color in extended-sRGB, 0...1 components. Sendable & Codable.
struct RGBAColor: Sendable, Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    init(_ nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.init(r: Double(c.redComponent),
                  g: Double(c.greenComponent),
                  b: Double(c.blueComponent),
                  a: Double(c.alphaComponent))
    }
}

/// SwiftUI Color bridge lives in the view layer; keep model free of SwiftUI.

/// Text horizontal alignment, Sendable mirror of NSTextAlignment.
enum TextAlignmentValue: String, Sendable, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }
}

/// A Sendable point in canvas (unit or pixel) space.
struct Point2D: Sendable, Codable, Hashable {
    var x: Double
    var y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    init(_ p: CGPoint) { self.x = Double(p.x); self.y = Double(p.y) }
    static let zero = Point2D(x: 0, y: 0)
}

/// A Sendable size in pixels.
struct Size2D: Sendable, Codable, Hashable {
    var width: Double
    var height: Double
    init(width: Double, height: Double) { self.width = width; self.height = height }
    var cgSize: CGSize { CGSize(width: width, height: height) }
    init(_ s: CGSize) { self.width = Double(s.width); self.height = Double(s.height) }
}

/// How the imported image is placed on the canvas.
enum ImageFit: String, Sendable, Codable, CaseIterable, Identifiable {
    case fit        // aspect-fit, letterboxed
    case fill       // aspect-fill, cropped
    case stretch    // fill exactly, distort
    case actual     // 1:1 pixels, centered
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        case .actual: return "Actual"
        }
    }
}

/// Canvas background style.
enum CanvasBackground: Sendable, Codable, Hashable {
    case transparent
    case solid(RGBAColor)

    var displayName: String {
        switch self {
        case .transparent: return "None"
        case .solid: return "Solid"
        }
    }
}
