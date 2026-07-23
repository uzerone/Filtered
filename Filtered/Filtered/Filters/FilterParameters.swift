import Foundation
import CoreImage

/// A single Sendable filter parameter value. Bridges to the concrete Core Image
/// value (NSNumber / CIVector / CIColor) at bind time, inside the render engine.
enum FilterValue: Sendable, Codable, Hashable {
    case scalar(Double)          // NSNumber
    case angle(Double)           // radians -> NSNumber
    case color(RGBAColor)        // CIColor
    case center(Point2D)         // CIVector (x, y) in pixel space
    case bool(Bool)              // NSNumber(0/1)

    var doubleValue: Double? {
        switch self {
        case .scalar(let v), .angle(let v): return v
        default: return nil
        }
    }
}

/// Sendable, Codable keyed bag of filter parameters. Keys are Core Image input
/// keys (e.g. "inputWidth"). This is what crosses the actor boundary.
struct FilterParameters: Sendable, Codable, Hashable {
    private(set) var values: [String: FilterValue]

    init(_ values: [String: FilterValue] = [:]) {
        self.values = values
    }

    subscript(key: String) -> FilterValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    mutating func set(_ key: String, _ value: FilterValue) {
        values[key] = value
    }

    func scaled(pixelKeys: Set<String>, by scale: Double) -> FilterParameters {
        guard scale != 1 else { return self }
        var copy = values
        for key in pixelKeys {
            if case .scalar(let v)? = copy[key] {
                copy[key] = .scalar(v * scale)
            }
        }
        return FilterParameters(copy)
    }
}
