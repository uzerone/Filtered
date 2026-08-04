import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Pure functions turning a FilterInstance into a concrete CIImage transform.
/// All filter names/keys are verified real on macOS 26.5. Runs off the main
/// actor inside RenderEngine — takes only Sendable inputs and CIImage.
enum CIFilterFactory {

    /// Apply one filter to `input`. `renderScale` scales pixel-space params so
    /// preview and export match. `extent` is the working image extent (used to
    /// resolve center points and crop infinite-extent generators).
    static func apply(_ instance: FilterInstance,
                      to input: CIImage,
                      renderScale: Double,
                      textureCache: GlassTextureCache) -> CIImage {
        let kind = instance.kind
        // Scale pixel-space params.
        let params = instance.parameters.scaled(pixelKeys: kind.pixelKeys, by: renderScale)
        let extent = input.extent.isInfinite ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : input.extent

        switch kind {
        case .grain:
            return applyGrain(params, to: input, extent: extent)
        case .gradientMap:
            return applyGradientMap(params, to: input)
        case .glass:
            return applyGlass(params, to: input, extent: extent,
                              renderScale: renderScale, cache: textureCache)
        case .invert:
            let f = CIFilter.colorInvert()
            f.inputImage = input
            return f.outputImage ?? input
        case .chromaticAberration:
            return applyChromaticAberration(params, to: input, extent: extent)
        case .scanlines:
            return applyScanlines(params, to: input, extent: extent)
        case .glitch:
            return applyGlitch(params, to: input, extent: extent, renderScale: renderScale)
        case .ascii:
            return applyASCII(params, to: input, extent: extent)
        case .pixelSort:
            return applyPixelSort(params, to: input, extent: extent, renderScale: renderScale)
        case .curves:
            return applyCurves(params, to: input)
        case .whiteBalance:
            return applyWhiteBalance(params, to: input)
        default:
            return applyStock(kind: kind, params: params, to: input, extent: extent)
        }
    }

    // MARK: - Generic stock-filter binding

    private static func applyStock(kind: FilterKind,
                                   params: FilterParameters,
                                   to input: CIImage,
                                   extent: CGRect) -> CIImage {
        guard let ciName = stockCIName(for: kind),
              let filter = CIFilter(name: ciName) else { return input }
        // Convolving filters sample neighbors; clamp so image edges don't
        // darken toward transparent (audited: 44% corner falloff on blur).
        let clampNeeded: Set<FilterKind> = [.bloom, .edges, .crystallize, .pointillize,
                                            .blur, .unsharpMask, .sharpenLuminance,
                                            .motionBlur, .zoomBlur, .noiseReduction,
                                            .highlightShadow]
        let fed = clampNeeded.contains(kind) ? input.clampedToExtent() : input
        filter.setValue(fed, forKey: kCIInputImageKey)

        for spec in kind.params {
            guard let value = params[spec.key] else { continue }
            switch spec.kind {
            case .scalar, .pixelScalar, .angle:
                if let d = value.doubleValue {
                    filter.setValue(d as NSNumber, forKey: spec.key)
                }
            case .bool:
                if case .bool(let b) = value {
                    filter.setValue(b ? 1 : 0, forKey: spec.key)
                }
            case .color:
                if case .color(let c) = value {
                    filter.setValue(CIColor(cgColor: c.cgColor), forKey: spec.key)
                }
            case .center:
                let center: CGPoint
                if case .center(let p) = value, p.x != 0 || p.y != 0 {
                    center = p.cgPoint
                } else {
                    center = CGPoint(x: extent.midX, y: extent.midY)
                }
                filter.setValue(CIVector(x: center.x, y: center.y), forKey: spec.key)
            }
        }

        // Some distortion/generator filters return an image larger/smaller than
        // input; crop pixel-family effects back to the source extent so the
        // canvas stays stable.
        let out = filter.outputImage ?? input
        switch kind.family {
        case .pixelate, .halftone, .distort, .stylize, .glitch, .adjust, .sharpen, .film:
            return out.cropped(to: extent)
        }
    }

    /// Verified real CIFilter(name:) strings.
    private static func stockCIName(for kind: FilterKind) -> String? {
        switch kind {
        case .halftoneCircle:   return "CICircularScreen"   // rings; use CIDotScreen for dots
        case .halftoneDots:     return "CIDotScreen"
        case .colorHalftone:    return "CICMYKHalftone"
        case .mosaic:           return "CIPixellate"
        case .mosaicTiles:      return "CIHexagonalPixellate"
        case .bump:             return "CIBumpDistortion"
        case .twirl:            return "CITwirlDistortion"
        case .threshold:        return "CIColorThreshold"
        case .posterize:        return "CIColorPosterize"
        case .monochrome:       return "CIColorMonochrome"
        case .colorControls:    return "CIColorControls"
        case .exposure:         return "CIExposureAdjust"
        case .gamma:            return "CIGammaAdjust"
        case .hue:              return "CIHueAdjust"
        case .vignette:         return "CIVignette"
        case .blur:             return "CIGaussianBlur"
        case .sharpenLuminance: return "CISharpenLuminance"
        case .unsharpMask:      return "CIUnsharpMask"
        case .comic:            return "CIComicEffect"
        case .edges:            return "CIEdges"
        case .crystallize:      return "CICrystallize"
        case .pointillize:      return "CIPointillize"
        case .bloom:            return "CIBloom"
        case .highlightShadow:  return "CIHighlightShadowAdjust"
        case .vibrance:         return "CIVibrance"
        case .motionBlur:       return "CIMotionBlur"
        case .zoomBlur:         return "CIZoomBlur"
        case .sepia:            return "CISepiaTone"
        case .filmChrome:       return "CIPhotoEffectChrome"
        case .filmFade:         return "CIPhotoEffectFade"
        case .filmInstant:      return "CIPhotoEffectInstant"
        case .filmNoir:         return "CIPhotoEffectNoir"
        case .filmTonal:        return "CIPhotoEffectTonal"
        case .filmTransfer:     return "CIPhotoEffectTransfer"
        case .kaleidoscope:     return "CIKaleidoscope"
        case .noiseReduction:   return "CINoiseReduction"
        case .glass, .grain, .gradientMap, .invert, .curves, .whiteBalance,
             .chromaticAberration, .scanlines, .glitch, .ascii, .pixelSort:
            return nil  // handled specially
        }
    }

    // MARK: - White balance (CITemperatureAndTint, composite neutral vector)

    /// Temperature/tint sliders drive the source-neutral vector against a fixed
    /// 6500K target: declaring the scene "bluer" (higher K) warms the image.
    private static func applyWhiteBalance(_ params: FilterParameters,
                                          to input: CIImage) -> CIImage {
        let temp = params["temp"]?.doubleValue ?? 6500
        let tint = params["tint"]?.doubleValue ?? 0
        guard abs(temp - 6500) > 1 || abs(tint) > 0.5 else { return input }
        let f = CIFilter.temperatureAndTint()
        f.inputImage = input
        f.neutral = CIVector(x: temp, y: tint)
        f.targetNeutral = CIVector(x: 6500, y: 0)
        return f.outputImage ?? input
    }

    // Note: halftoneCircle uses CICircularScreen which lacks inputAngle — its
    // param list omits angle accordingly; the generic binder skips missing keys.

    // MARK: - Grain (composite recipe, verified)

    private static func applyGrain(_ params: FilterParameters,
                                   to input: CIImage,
                                   extent: CGRect) -> CIImage {
        let amount = params["grainAmount"]?.doubleValue ?? 0.15

        let noise = CIFilter.randomGenerator().outputImage ?? CIImage.empty()
        let croppedNoise = noise.cropped(to: extent)

        // Collapse RGB to gray, set alpha ~= amount → faint gray speckle.
        let mono = CIFilter.colorMatrix()
        mono.inputImage = croppedNoise
        mono.rVector = CIVector(x: 0.333, y: 0.333, z: 0.333, w: 0)
        mono.gVector = CIVector(x: 0.333, y: 0.333, z: 0.333, w: 0)
        mono.bVector = CIVector(x: 0.333, y: 0.333, z: 0.333, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: amount)
        mono.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let grainLayer = mono.outputImage else { return input }

        let comp = CIFilter.sourceOverCompositing()
        comp.inputImage = grainLayer.cropped(to: extent)
        comp.backgroundImage = input
        return (comp.outputImage ?? input).cropped(to: extent)
    }

    // MARK: - Gradient Map (composite recipe, verified)

    private static func applyGradientMap(_ params: FilterParameters,
                                         to input: CIImage) -> CIImage {
        var shadow = RGBAColor(r: 0.05, g: 0.02, b: 0.15)
        var highlight = RGBAColor(r: 1.0, g: 0.85, b: 0.3)
        if case .color(let c)? = params["shadow"] { shadow = c }
        if case .color(let c)? = params["highlight"] { highlight = c }

        // Stage 1: desaturate to luminance.
        let mono = CIFilter.photoEffectMono()
        mono.inputImage = input
        let gray = mono.outputImage ?? input

        // Stage 2: 256x1 horizontal gradient as the color LUT.
        let grad = CIFilter.linearGradient()
        grad.point0 = CGPoint(x: 0, y: 0)
        grad.point1 = CGPoint(x: 256, y: 0)
        grad.color0 = CIColor(cgColor: shadow.cgColor)
        grad.color1 = CIColor(cgColor: highlight.cgColor)
        let gradientImage = (grad.outputImage ?? CIImage.empty())
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 1))

        let map = CIFilter.colorMap()
        map.inputImage = gray
        map.gradientImage = gradientImage
        return map.outputImage ?? input
    }

    // MARK: - Glass (requires a texture, verified)

    private static func applyGlass(_ params: FilterParameters,
                                   to input: CIImage,
                                   extent: CGRect,
                                   renderScale: Double,
                                   cache: GlassTextureCache) -> CIImage {
        let scale = params["inputScale"]?.doubleValue ?? 120
        // Texture cell size scales with resolution so preview matches export.
        let texture = cache.texture(for: extent, cellScale: renderScale)

        guard let filter = CIFilter(name: "CIGlassDistortion") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(texture, forKey: "inputTexture")
        filter.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        filter.setValue(scale as NSNumber, forKey: "inputScale")
        return (filter.outputImage ?? input).cropped(to: extent)
    }

    // MARK: - Chromatic aberration (RGB channel offset)

    /// Splits R and B channels and offsets them in opposite directions along an
    /// angle, using CIColorMatrix to isolate channels + additive compositing.
    private static func applyChromaticAberration(_ params: FilterParameters,
                                                 to input: CIImage,
                                                 extent: CGRect) -> CIImage {
        let amount = params["amount"]?.doubleValue ?? 6
        let angle = params["angle"]?.doubleValue ?? 0
        guard amount > 0 else { return input }
        let dx = CGFloat(cos(angle) * amount)
        let dy = CGFloat(sin(angle) * amount)
        let src = input.clampedToExtent()

        func channel(_ r: Double, _ g: Double, _ b: Double, offset: CGPoint) -> CIImage {
            let m = CIFilter.colorMatrix()
            m.inputImage = src
            m.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let img = m.outputImage ?? src
            return img.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
        }

        let rImg = channel(1, 0, 0, offset: CGPoint(x: dx, y: dy))
        let gImg = channel(0, 1, 0, offset: .zero)
        let bImg = channel(0, 0, 1, offset: CGPoint(x: -dx, y: -dy))

        // Additive screen of the three channels.
        func add(_ a: CIImage, _ b: CIImage) -> CIImage {
            let f = CIFilter.additionCompositing()
            f.inputImage = a; f.backgroundImage = b
            return f.outputImage ?? b
        }
        return add(rImg, add(gImg, bImg)).cropped(to: extent)
    }

    // MARK: - Scanlines (CRT-style horizontal lines)

    private static func applyScanlines(_ params: FilterParameters,
                                       to input: CIImage,
                                       extent: CGRect) -> CIImage {
        let spacing = max(params["spacing"]?.doubleValue ?? 3, 1)
        let intensity = params["intensity"]?.doubleValue ?? 0.4
        guard intensity > 0 else { return input }

        // Build a horizontal-line pattern via a stripe: y-modulated darkening.
        // Use a sine-based generator approximated with CICheckerboard? Simpler:
        // render a repeating gradient stripe using CILinearGradient tiled — but
        // the cleanest stock route is a small stripe image tiled with CIAffineTile.
        let lineDark = 1.0 - intensity
        // One stripe cell: top half bright (1), bottom half dark (lineDark).
        let cellHeight = spacing
        let bright = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: cellHeight/2, width: 4, height: cellHeight/2))
        let dark = CIImage(color: CIColor(red: lineDark, green: lineDark, blue: lineDark))
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: cellHeight/2))
        let cell = bright.composited(over: dark)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: cellHeight))

        let tile = CIFilter.affineTile()
        tile.inputImage = cell
        tile.transform = CGAffineTransform.identity
        let pattern = (tile.outputImage ?? cell).cropped(to: extent)

        // Multiply the pattern over the image.
        let mult = CIFilter.multiplyCompositing()
        mult.inputImage = pattern
        mult.backgroundImage = input
        return (mult.outputImage ?? input).cropped(to: extent)
    }

    // MARK: - Glitch (channel shift + horizontal slice displacement, stock CI)

    private static func applyGlitch(_ params: FilterParameters,
                                    to input: CIImage,
                                    extent: CGRect,
                                    renderScale: Double) -> CIImage {
        let amount = params["amount"]?.doubleValue ?? 0.5
        let seed = params["seed"]?.doubleValue ?? 7
        let sliceH = max(params["sliceHeight"]?.doubleValue ?? 20, 2)
        guard amount > 0 else { return input }

        let src = input.clampedToExtent()
        var result = src

        // 1. RGB channel split (chromatic shift) proportional to amount.
        //    Pixel constants scale with renderScale so export matches preview.
        let shift = CGFloat(amount * 14 * renderScale)
        func chan(_ r: Double, _ g: Double, _ b: Double, dx: CGFloat) -> CIImage {
            let m = CIFilter.colorMatrix()
            m.inputImage = src
            m.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: r + g + b)
            return (m.outputImage ?? src).transformed(by: CGAffineTransform(translationX: dx, y: 0))
        }
        let rI = chan(1, 0, 0, dx: shift)
        let gI = chan(0, 1, 0, dx: 0)
        let bI = chan(0, 0, 1, dx: -shift)
        func add(_ a: CIImage, _ b: CIImage) -> CIImage {
            let f = CIFilter.additionCompositing(); f.inputImage = a; f.backgroundImage = b
            return f.outputImage ?? b
        }
        result = add(rI, add(gI, bI))

        // 2. Horizontal slice displacement: cut a few bands and shove them sideways.
        var seededRand = SeededRandom(seed: UInt64(seed) &+ 1)
        let bandCount = Int(max(extent.height / CGFloat(sliceH), 1))
        var composed = result
        for i in 0..<min(bandCount, 60) {
            // Only some bands glitch, gated by amount.
            if seededRand.next01() > amount { continue }
            let y = CGFloat(i) * CGFloat(sliceH)
            let bandRect = CGRect(x: extent.minX, y: extent.minY + y,
                                  width: extent.width, height: CGFloat(sliceH))
            let dir: CGFloat = seededRand.next01() < 0.5 ? -1 : 1
            let dx = dir * CGFloat(seededRand.next01()) * 60 * CGFloat(amount * renderScale)
            let slice = result.cropped(to: bandRect)
                .transformed(by: CGAffineTransform(translationX: dx, y: 0))
            composed = slice.composited(over: composed)
        }
        return composed.cropped(to: extent)
    }

    // MARK: - ASCII art (pixellate → luminance → posterize, stock approximation)

    /// Approximates ASCII/character art without a Metal atlas: downsample to
    /// cells, posterize luminance into distinct "density" bands, and overlay a
    /// dot/line grid so cells read as character-like marks.
    private static func applyASCII(_ params: FilterParameters,
                                   to input: CIImage,
                                   extent: CGRect) -> CIImage {
        let cell = max(params["cellSize"]?.doubleValue ?? 10, 4)

        // Desaturate.
        let mono = CIFilter.photoEffectMono()
        mono.inputImage = input
        let gray = mono.outputImage ?? input

        // Pixellate into cells.
        let px = CIFilter.pixellate()
        px.inputImage = gray
        px.scale = Float(cell)
        px.center = CGPoint(x: extent.midX, y: extent.midY)
        let blocks = (px.outputImage ?? gray).cropped(to: extent)

        // Posterize luminance into ~6 density levels (like a char ramp).
        let post = CIFilter.colorPosterize()
        post.inputImage = blocks
        post.levels = 6
        let banded = (post.outputImage ?? blocks).cropped(to: extent)

        // Overlay a character-cell grid (dot screen) so each cell has structure.
        guard let dot = CIFilter(name: "CIDotScreen") else { return banded }
        dot.setValue(banded, forKey: kCIInputImageKey)
        dot.setValue(cell as NSNumber, forKey: "inputWidth")
        dot.setValue(0.9 as NSNumber, forKey: "inputSharpness")
        dot.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        return (dot.outputImage ?? banded).cropped(to: extent)
    }

    // MARK: - Curves (CIToneCurve, five fixed-x points)

    private static func applyCurves(_ params: FilterParameters,
                                    to input: CIImage) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = input
        let xs: [Double] = [0, 0.25, 0.5, 0.75, 1]
        let defaults: [Double] = xs
        let ys: [Double] = (0..<5).map { i in
            params["y\(i)"]?.doubleValue ?? defaults[i]
        }
        f.point0 = CGPoint(x: xs[0], y: ys[0])
        f.point1 = CGPoint(x: xs[1], y: ys[1])
        f.point2 = CGPoint(x: xs[2], y: ys[2])
        f.point3 = CGPoint(x: xs[3], y: ys[3])
        f.point4 = CGPoint(x: xs[4], y: ys[4])
        return f.outputImage ?? input
    }

    // MARK: - Pixel sort (approximation via directional streak blur on bright areas)

    private static func applyPixelSort(_ params: FilterParameters,
                                       to input: CIImage,
                                       extent: CGRect,
                                       renderScale: Double) -> CIImage {
        let amount = params["amount"]?.doubleValue ?? 0.5
        guard amount > 0 else { return input }
        // Motion blur creates the horizontal "sorted streak" look.
        guard let mb = CIFilter(name: "CIMotionBlur") else { return input }
        mb.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        mb.setValue((amount * 60 * renderScale) as NSNumber, forKey: "inputRadius")
        mb.setValue(0 as NSNumber, forKey: "inputAngle")   // horizontal
        let blurred = (mb.outputImage ?? input).cropped(to: extent)
        // Blend blurred streaks over original by amount using lighten.
        let f = CIFilter.lightenBlendMode()
        f.inputImage = blurred
        f.backgroundImage = input
        return (f.outputImage ?? input).cropped(to: extent)
    }
}

/// Small deterministic PRNG (xorshift) so glitch is stable across re-renders.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func next01() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}

/// Caches the frosted-glass displacement texture per (extent, cellScale) so
/// preview & export use consistent glass cells at their respective resolutions.
/// Not Sendable state — owned by the RenderEngine actor.
final class GlassTextureCache {
    private var cached: (size: CGSize, cellScale: Double, image: CIImage)?

    func texture(for extent: CGRect, cellScale: Double) -> CIImage {
        if let c = cached, c.size == extent.size, c.cellScale == cellScale { return c.image }
        // Generate the texture at REFERENCE (1×) resolution and upscale it to
        // the target. This way preview and export see the SAME cell pattern,
        // just at different resolutions — sampling fresh noise per resolution
        // would produce a different glass pattern at export than in preview.
        //
        // Sharp noise gives strong local gradients — which is what drives
        // CIGlassDistortion's refraction; a mild pixellate makes "glass blocks".
        let scale = max(cellScale, 0.01)
        let baseRect = CGRect(x: 0, y: 0,
                              width: max(extent.width / scale, 1),
                              height: max(extent.height / scale, 1))
        let noise = (CIFilter.randomGenerator().outputImage ?? CIImage.empty())
            .cropped(to: baseRect)
        let px = CIFilter.pixellate()
        px.inputImage = noise
        px.scale = 6
        px.center = CGPoint(x: baseRect.midX, y: baseRect.midY)
        let baseTex = (px.outputImage ?? noise).cropped(to: baseRect)
        let tex = baseTex
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: extent)
        cached = (extent.size, cellScale, tex)
        return tex
    }
}
