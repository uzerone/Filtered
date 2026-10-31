import Foundation

/// One applied filter in a stack: which kind, whether it's enabled, its params.
/// Fully Sendable + Codable so it can cross into the render actor and be saved.
struct FilterInstance: Identifiable, Sendable, Codable, Hashable {
    let id: UUID
    var kind: FilterKind
    var isEnabled: Bool
    var parameters: FilterParameters

    init(kind: FilterKind, isEnabled: Bool = true, parameters: FilterParameters? = nil) {
        self.id = UUID()
        self.kind = kind
        self.isEnabled = isEnabled
        self.parameters = parameters ?? kind.defaultParameters()
    }
}
