import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// Off-main-actor renderer. Owns ONE shared Metal-backed CIContext (creating a
/// CIContext is expensive; CIContext is internally thread-safe for rendering).
/// Takes only the Sendable RenderRequest and returns a CGImage (which we box as
/// unchecked-Sendable to hand back to the main actor).
actor RenderEngine {
    static let shared = RenderEngine()

    private let context: CIContext
    private let glassCache = GlassTextureCache()
    private let outColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .highQualityDownsample: true,
            ])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    /// Render the request to a CGImage at canvasPixelSize * renderScale.
    func render(_ request: RenderRequest) -> SendableCGImage? {
        let scale = request.renderScale
        let outSize = CGSize(width: request.canvasPixelSize.width * scale,
                             height: request.canvasPixelSize.height * scale)
        let canvasRect = CGRect(origin: .zero, size: outSize)
        guard outSize.width >= 1, outSize.height >= 1 else { return nil }

        // Canvas background, then process the flat layer stack bottom-to-top.
        // Content layers (image/text) composite ON TOP of the running result.
        // Filter layers transform the ENTIRE running composite beneath them
        // (Photoshop adjustment-layer semantics), honoring layer opacity as a
        // wet/dry blend between the unfiltered and filtered composite.
        var composite = backgroundImage(request.background, rect: canvasRect)

        for layer in request.layers where layer.isVisible {
            switch layer.kind {
            case .filter:
                guard let f = layer.filter, f.isEnabled else { continue }
                let filtered = CIFilterFactory.apply(f, to: composite,
                                                     renderScale: scale,
                                                     textureCache: glassCache)
                    .cropped(to: canvasRect)
                // opacity < 1 => blend filtered over original (partial strength).
                if layer.opacity >= 1 {
                    composite = filtered
                } else {
                    let wet = applyOpacity(filtered, opacity: layer.opacity)
                    composite = over(wet, background: composite, rect: canvasRect)
                }

            case .image:
                guard let base = request.base else { continue }
                let img = placeImage(base.image, in: canvasRect, fit: request.imageFit)
                composite = over(applyOpacity(img, opacity: layer.opacity),
                                 background: composite, rect: canvasRect)

            case .text:
                guard let textImg = layer.textImage?.image else { continue }
                let img = positionText(textImg, layer: layer, canvasRect: canvasRect)
                composite = over(applyOpacity(img, opacity: layer.opacity),
                                 background: composite, rect: canvasRect)
            }
        }

        composite = composite.cropped(to: canvasRect)

        return context.createCGImage(composite,
                                     from: canvasRect,
                                     format: .RGBA8,
                                     colorSpace: outColorSpace)
            .map(SendableCGImage.init)
    }

    // MARK: - Placement & compositing helpers

    private func placeImage(_ image: CIImage, in canvasRect: CGRect, fit: ImageFit) -> CIImage {
        let src = image.extent
        guard src.width > 0, src.height > 0 else { return image }
        let sx = canvasRect.width / src.width
        let sy = canvasRect.height / src.height
        let factor: CGFloat
        switch fit {
        case .fit:    factor = min(sx, sy)
        case .fill:   factor = max(sx, sy)
        case .actual: factor = 1
        case .stretch:
            let t = CGAffineTransform(scaleX: sx, y: sy)
            let scaled = image.transformed(by: t)
            return centered(scaled, in: canvasRect)
        }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return centered(scaled, in: canvasRect)
    }

    private func centered(_ image: CIImage, in canvasRect: CGRect) -> CIImage {
        let e = image.extent
        let dx = canvasRect.midX - e.midX
        let dy = canvasRect.midY - e.midY
        return image.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    private func positionText(_ textImage: CIImage, layer: RenderLayer, canvasRect: CGRect) -> CIImage {
        let e = textImage.extent
        // position is normalized center 0..1 (y is top-based in the UI; Core Image
        // is bottom-based, so flip y).
        let cx = canvasRect.width * layer.position.x
        let cy = canvasRect.height * (1 - layer.position.y)
        var img = textImage
        if layer.rotation != 0 {
            let toCenter = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            let rot = CGAffineTransform(rotationAngle: layer.rotation)
            img = img.transformed(by: toCenter.concatenating(rot))
        }
        let curr = img.extent
        let dx = cx - curr.midX
        let dy = cy - curr.midY
        return img.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    private func applyOpacity(_ image: CIImage, opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
        return f.outputImage ?? image
    }

    private func over(_ image: CIImage, background: CIImage, rect: CGRect) -> CIImage {
        let f = CIFilter.sourceOverCompositing()
        f.inputImage = image
        f.backgroundImage = background
        return (f.outputImage ?? background).cropped(to: rect)
    }

    private func backgroundImage(_ bg: CanvasBackground, rect: CGRect) -> CIImage {
        switch bg {
        case .transparent:
            return CIImage.empty().cropped(to: rect)
        case .solid(let color):
            let ci = CIColor(cgColor: color.cgColor)
            return CIImage(color: ci).cropped(to: rect)
        }
    }
}

/// Unchecked-Sendable box for a CGImage crossing back to the main actor.
struct SendableCGImage: @unchecked Sendable {
    let cgImage: CGImage
    init(_ cgImage: CGImage) { self.cgImage = cgImage }
}
