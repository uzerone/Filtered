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
    }

    struct LayerState: Codable, Equatable {
        var id: UUID
        var name: String
        var kind: LayerKindCode
        var isVisible: Bool
        var opacity: Double
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
