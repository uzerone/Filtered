import Foundation
import CoreImage

/// A fully Sendable snapshot of everything needed to render one frame.
/// Built SYNCHRONOUSLY on the @MainActor from the (non-Sendable) model, then
/// handed to the RenderEngine actor. This boundary is what satisfies Swift 6.3
/// strict concurrency (CIImage/CIContext/@Observable are not Sendable).
struct RenderRequest: Sendable {
    /// The base image already wrapped as a CIImage. CIImage is immutable and,
    /// while not marked Sendable by the SDK, is safe to hand off as an opaque
    /// value here because we never mutate it; we pass it via an unchecked box.
    let base: SendableCIImage?
    let canvasPixelSize: Size2D
    let background: CanvasBackground
    let imageFit: ImageFit
    /// renderScale = outputPixelWidth / canvasWidth. 1.0 for preview at canvas
    /// size; >1 (or =1) for full-res export. Pixel-space filter params multiply
    /// by this so preview and export match.
    let renderScale: Double
    let layers: [RenderLayer]

    /// Source-image orientation: quarter-turns clockwise, mirror first.
    let orientationQuarters: Int
    let flippedH: Bool
    /// Subject cutout: when set, the base image is masked to the subject
    /// (mask is at source resolution, same orientation pipeline as the base).
    let subjectMask: SendableCIImage?
    /// Normalized crop of the oriented source (CI coords, bottom-left origin).
    let cropRect: CGRect?
}

/// A Sendable per-layer render description.
struct RenderLayer: Sendable {
    let kind: LayerKindSnapshot
    let isVisible: Bool
    let opacity: Double
    let blendMode: LayerBlendMode
    /// For .filter layers: the filter to apply to the composite below.
    let filter: FilterInstance?
    /// For text layers: the pre-rendered text image (rendered on @MainActor) and
    /// its normalized center position.
    let textImage: SendableCIImage?
    let position: Point2D
    let rotation: Double
}

enum LayerKindSnapshot: Sendable {
    case image
    case text
    case filter
}

/// Unchecked-Sendable wrapper around a CIImage. CIImage is a value-semantics,
/// immutable recipe object; we only read it inside the render actor. This is the
/// standard, documented way to move CIImages across isolation domains.
struct SendableCIImage: @unchecked Sendable {
    let image: CIImage
    init(_ image: CIImage) { self.image = image }
}
