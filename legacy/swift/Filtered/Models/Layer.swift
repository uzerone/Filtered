import Foundation
import Observation
import CoreImage

/// What a layer contains.
enum LayerKind: Sendable, Equatable {
    case image      // the imported base photo
    case text       // a text overlay
    case filter     // an adjustment/filter layer — affects everything below it
    case group      // a folder of layers applied together as one unit
}

/// How a layer composites over what's beneath it. For filter layers this is
/// how the filtered result blends back over the unfiltered composite.
enum LayerBlendMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case normal, multiply, screen, overlay, softLight, darken, lighten, difference
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .softLight: return "Soft Light"
        case .darken: return "Darken"
        case .lighten: return "Lighten"
        case .difference: return "Difference"
        }
    }

    /// The verified Core Image compositing filter for this mode.
    var ciFilterName: String {
        switch self {
        case .normal: return "CISourceOverCompositing"
        case .multiply: return "CIMultiplyBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .darken: return "CIDarkenBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .difference: return "CIDifferenceBlendMode"
        }
    }
}

/// A single layer in the document. @MainActor @Observable reference type so the
/// inspector and drag gestures mutate it in place while identity is preserved
/// for selection. Never crosses the render actor — a Sendable snapshot does.
///
/// The document is a FLAT stack of layers rendered bottom-to-top. A `.filter`
/// layer applies its CIFilter to the accumulated composite beneath it (like a
/// Photoshop adjustment layer), so filters are first-class layers, not children.
@MainActor
@Observable
final class Layer: Identifiable {
    let id: UUID
    var name: String
    var kind: LayerKind
    var isVisible: Bool
    var opacity: Double            // 0...1
    var blendMode: LayerBlendMode = .normal

    /// The filter payload (only for .filter layers).
    var filter: FilterInstance?

    /// Text payload (only for .text layers).
    var text: TextContent?

    /// Normalized position of the layer's center on the canvas, 0...1 in each axis.
    /// (0.5, 0.5) = centered. Used by text layers; image layer uses canvas fit.
    var position: Point2D

    /// Rotation in radians (text layers).
    var rotation: Double

    /// Child layers (only for .group layers), bottom-to-top like the main
    /// stack. One level deep: groups never contain other groups.
    var children: [Layer]

    init(id: UUID = UUID(),
         name: String,
         kind: LayerKind,
         isVisible: Bool = true,
         opacity: Double = 1,
         blendMode: LayerBlendMode = .normal,
         filter: FilterInstance? = nil,
         text: TextContent? = nil,
         position: Point2D = Point2D(x: 0.5, y: 0.5),
         rotation: Double = 0,
         children: [Layer] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
        self.filter = filter
        self.text = text
        self.position = position
        self.rotation = rotation
        self.children = children
    }

    // MARK: Text rasterization cache
    // Re-rendering a text layer's bitmap on every preview tick is wasteful and
    // ran on the main thread per slider tick. Cache the CIImage keyed by
    // (content hash, scale); @ObservationIgnored so cache writes don't trigger
    // SwiftUI invalidation loops.
    @ObservationIgnored private var textCacheKey: Int = 0
    @ObservationIgnored private var textCacheScale: Double = -1
    @ObservationIgnored private var textCacheImage: CIImage?

    /// Rasterized text image for this layer at `scale`, re-rendered only when
    /// the text content or scale changed since the last call.
    func cachedTextImage(scale: Double) -> CIImage? {
        guard let content = text else { return nil }
        var hasher = Hasher()
        content.hash(into: &hasher)
        let key = hasher.finalize()
        if key == textCacheKey, scale == textCacheScale, let cached = textCacheImage {
            return cached
        }
        let rendered = TextRenderer.render(content, scale: scale)
        textCacheKey = key
        textCacheScale = scale
        textCacheImage = rendered
        return rendered
    }

    static func imageLayer() -> Layer {
        Layer(name: "Image", kind: .image)
    }

    static func textLayer(_ content: TextContent = TextContent()) -> Layer {
        Layer(name: content.string.isEmpty ? "Text" : String(content.string.prefix(12)),
              kind: .text,
              text: content)
    }

    static func filterLayer(_ kind: FilterKind) -> Layer {
        Layer(name: kind.displayName,
              kind: .filter,
              filter: FilterInstance(kind: kind))
    }

    static func groupLayer(name: String = "Group", children: [Layer] = []) -> Layer {
        Layer(name: name, kind: .group, children: children)
    }
}
