import Foundation
import Observation

/// What a layer contains.
enum LayerKind: Sendable, Equatable {
    case image      // the imported base photo
    case text       // a text overlay
    case filter     // an adjustment/filter layer — affects everything below it
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

    /// The filter payload (only for .filter layers).
    var filter: FilterInstance?

    /// Text payload (only for .text layers).
    var text: TextContent?

    /// Normalized position of the layer's center on the canvas, 0...1 in each axis.
    /// (0.5, 0.5) = centered. Used by text layers; image layer uses canvas fit.
    var position: Point2D

    /// Rotation in radians (text layers).
    var rotation: Double

    init(id: UUID = UUID(),
         name: String,
         kind: LayerKind,
         isVisible: Bool = true,
         opacity: Double = 1,
         filter: FilterInstance? = nil,
         text: TextContent? = nil,
         position: Point2D = Point2D(x: 0.5, y: 0.5),
         rotation: Double = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isVisible = isVisible
        self.opacity = opacity
        self.filter = filter
        self.text = text
        self.position = position
        self.rotation = rotation
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
}
