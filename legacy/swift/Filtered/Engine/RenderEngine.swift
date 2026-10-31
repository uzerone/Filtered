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
        // Renders serialize on this actor; a preview tick cancelled while
        // waiting in line should not still pay for a full render.
        guard !Task.isCancelled else { return nil }
        let scale = request.renderScale
        let outSize = CGSize(width: request.canvasPixelSize.width * scale,
                             height: request.canvasPixelSize.height * scale)
        let canvasRect = CGRect(origin: .zero, size: outSize)
        guard outSize.width >= 1, outSize.height >= 1 else { return nil }

        // Canvas background, then process the layer stack bottom-to-top.
        // Content layers (image/text) composite ON TOP of the running result.
        // Filter layers transform the ENTIRE running composite beneath them
        // (Photoshop adjustment-layer semantics), honoring layer opacity as a
        // wet/dry blend between the unfiltered and filtered composite.
        let background = backgroundImage(request.background, rect: canvasRect)
        let composite = compositeStack(request.layers, startingFrom: background,
                                       request: request, canvasRect: canvasRect)
            .cropped(to: canvasRect)

        return context.createCGImage(composite,
                                     from: canvasRect,
                                     format: .RGBA8,
                                     colorSpace: outColorSpace)
            .map(SendableCGImage.init)
    }

    /// Render a layer stack bottom-to-top over `start`. Called recursively for
    /// groups: a group's children render as a sub-stack starting from the
    /// composite below the group (so filters inside behave exactly as if
    /// inline), then the combined result blends back with the GROUP's
    /// opacity/blend mode — one wet/dry control for the whole folder.
    private func compositeStack(_ layers: [RenderLayer],
                                startingFrom start: CIImage,
                                request: RenderRequest,
                                canvasRect: CGRect) -> CIImage {
        let scale = request.renderScale
        var composite = start

        for layer in layers where layer.isVisible {
            switch layer.kind {
            case .filter:
                guard let f = layer.filter, f.isEnabled else { continue }
                let filtered = CIFilterFactory.apply(f, to: composite,
                                                     renderScale: scale,
                                                     textureCache: glassCache)
                    .cropped(to: canvasRect)
                // Fast path: full-strength normal blend replaces outright.
                if layer.opacity >= 1 && layer.blendMode == .normal {
                    composite = filtered
                } else {
                    // Wet/dry + blend mode: the filtered result composites back
                    // over the unfiltered image with the chosen mode.
                    let wet = applyOpacity(filtered, opacity: layer.opacity)
                    composite = blend(wet, over: composite,
                                      mode: layer.blendMode, rect: canvasRect)
                }

            case .image:
                guard let base = request.base else { continue }
                var source = base.image
                // Subject cutout: mask BEFORE orientation/placement (the mask
                // is at source resolution and goes through the same transforms).
                if let mask = request.subjectMask {
                    source = applyMask(mask.image, to: source)
                }
                // Rotate / flip, then crop (crop is stored in oriented space).
                source = orient(source,
                                quarters: request.orientationQuarters,
                                flippedH: request.flippedH)
                if let crop = request.cropRect {
                    source = applyCrop(crop, to: source)
                }
                let img = placeImage(source, in: canvasRect, fit: request.imageFit)
                composite = blend(applyOpacity(img, opacity: layer.opacity),
                                  over: composite, mode: layer.blendMode, rect: canvasRect)

            case .text:
                guard let textImg = layer.textImage?.image else { continue }
                let img = positionText(textImg, layer: layer, canvasRect: canvasRect)
                composite = blend(applyOpacity(img, opacity: layer.opacity),
                                  over: composite, mode: layer.blendMode, rect: canvasRect)

            case .group:
                guard let children = layer.children, !children.isEmpty else { continue }
                let grouped = compositeStack(children, startingFrom: composite,
                                             request: request, canvasRect: canvasRect)
                    .cropped(to: canvasRect)
                if layer.opacity >= 1 && layer.blendMode == .normal {
                    composite = grouped
                } else {
                    let wet = applyOpacity(grouped, opacity: layer.opacity)
                    composite = blend(wet, over: composite,
                                      mode: layer.blendMode, rect: canvasRect)
                }
            }
        }
        return composite
    }

    // MARK: - Placement & compositing helpers

    /// Crop the oriented source by a normalized rect (CI bottom-left coords),
    /// re-normalized so the extent origin returns to (0,0).
    private func applyCrop(_ crop: CGRect, to image: CIImage) -> CIImage {
        let e = image.extent
        let r = CGRect(x: e.minX + crop.minX * e.width,
                       y: e.minY + crop.minY * e.height,
                       width: crop.width * e.width,
                       height: crop.height * e.height)
        guard r.width >= 1, r.height >= 1 else { return image }
        return image.cropped(to: r)
            .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    /// Composite with a blend mode; .normal is plain source-over.
    private func blend(_ image: CIImage, over background: CIImage,
                       mode: LayerBlendMode, rect: CGRect) -> CIImage {
        guard mode != .normal else { return over(image, background: background, rect: rect) }
        guard let f = CIFilter(name: mode.ciFilterName) else {
            return over(image, background: background, rect: rect)
        }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(background, forKey: kCIInputBackgroundImageKey)
        return (f.outputImage ?? background).cropped(to: rect)
    }

    /// Keep only the masked subject (white = keep), transparent elsewhere.
    private func applyMask(_ mask: CIImage, to image: CIImage) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = image
        f.backgroundImage = CIImage.empty().cropped(to: image.extent)
        f.maskImage = mask
        return (f.outputImage ?? image).cropped(to: image.extent)
    }

    /// Mirror-then-rotate the source (quarter-turns clockwise on screen),
    /// re-normalized so the extent origin stays at (0,0).
    private func orient(_ image: CIImage, quarters: Int, flippedH: Bool) -> CIImage {
        var img = image
        if flippedH {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        }
        let q = ((quarters % 4) + 4) % 4
        if q != 0 {
            // Core Image is bottom-up: a visually-clockwise turn is -90°.
            img = img.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(q) * .pi / 2))
        }
        let e = img.extent
        return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

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
