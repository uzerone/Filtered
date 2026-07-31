import Foundation

/// A pure-value snapshot of the editable document state (everything EXCEPT the
/// source pixels, which don't change on undoable edits). Used by the undo system
/// to capture and restore state. Codable so it could also back save/open later.
struct DocumentSnapshot: Codable, Equatable {
    var canvas: CanvasState
    var layers: [LayerState]
    var selectedLayerID: UUID?

    struct CanvasState: Codable, Equatable {
        var width: Int
        var height: Int
        var background: CanvasBackground
        var imageFit: ImageFit
        var dpi: Int
        // Optional so pre-existing .ftrd files (and older app versions reading
        // new files) keep decoding: JSONDecoder treats missing keys as nil and
        // ignores unknown keys.
        /// Source-image orientation: quarter-turns clockwise (0–3).
        var orientationQuarters: Int?
        /// Source-image horizontal mirror, applied before rotation.
        var flippedH: Bool?
        /// Subject cutout active (mask recomputed on load when true).
        var backgroundRemoved: Bool?
        /// Normalized crop of the oriented source image, Core Image coordinates
        /// (origin bottom-left). Nil/absent = no crop.
        var cropX: Double?
        var cropY: Double?
        var cropW: Double?
        var cropH: Double?
    }

    struct LayerState: Codable, Equatable {
        var id: UUID
        var name: String
        var kind: LayerKindCode
        var isVisible: Bool
        var opacity: Double
        /// Raw LayerBlendMode; optional so old files decode (nil = normal).
        var blendMode: String?
        var filter: FilterInstance?
        var text: TextContent?
        var position: Point2D
        var rotation: Double
    }

    enum LayerKindCode: String, Codable {
        case image, text, filter
    }
}

extension LayerKind {
    var code: DocumentSnapshot.LayerKindCode {
        switch self {
        case .image: return .image
        case .text: return .text
        case .filter: return .filter
        }
    }
    init(_ code: DocumentSnapshot.LayerKindCode) {
        switch code {
        case .image: self = .image
        case .text: self = .text
        case .filter: self = .filter
        }
    }
}
