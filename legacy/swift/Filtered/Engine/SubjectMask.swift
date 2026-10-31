import Foundation
import CoreImage
import Vision

/// Generates a subject (foreground) mask for an image using Vision — the
/// engine behind "Cut Out Subject". Runs off the main actor; the heavy work is
/// Apple's segmentation model on the Neural Engine.
enum SubjectMask {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Compute a soft foreground mask (white = subject) at source resolution.
    /// Returns nil if no subject was found.
    static func compute(for image: CIImage) async -> SendableCIImage? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1,
              let cg = context.createCGImage(image, from: extent) else { return nil }

        return await Task.detached(priority: .userInitiated) { () -> SendableCIImage? in
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg)
            do {
                try handler.perform([request])
                guard let result = request.results?.first, !result.allInstances.isEmpty else {
                    return nil
                }
                let maskBuffer = try result.generateScaledMaskForImage(
                    forInstances: result.allInstances, from: handler)
                let mask = CIImage(cvPixelBuffer: maskBuffer)
                // Scale the mask to exactly match the source extent (Vision may
                // return a different resolution).
                let sx = extent.width / mask.extent.width
                let sy = extent.height / mask.extent.height
                let scaled = mask
                    .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                return SendableCIImage(scaled)
            } catch {
                return nil
            }
        }.value
    }
}
