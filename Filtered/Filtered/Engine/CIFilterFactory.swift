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
            return applyGlass(params, to: input, extent: extent, cache: textureCache)
        case .invert:
            let f = CIFilter.colorInvert()
            f.inputImage = input
            return f.outputImage ?? input
        case .chromaticAberration:
            return applyChromaticAberration(params, to: input, extent: extent)
        case .scanlines:
            return applyScanlines(params, to: input, extent: extent)
        case .glitch:
            return applyGlitch(params, to: input, extent: extent)
        case .ascii:
            return applyASCII(params, to: input, extent: extent)
        case .pixelSort:
            return applyPixelSort(params, to: input, extent: extent)
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
        // Radius-based stylize filters (bloom/edges/blur-like) sample neighbors;
        // clamp so image edges don't darken to transparent.
        let clampNeeded: Set<FilterKind> = [.bloom, .edges, .crystallize, .pointillize]
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
        case .pixelate, .halftone, .distort, .stylize, .glitch, .adjust, .sharpen:
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
        case .glass, .grain, .gradientMap, .invert,
             .chromaticAberration, .scanlines, .glitch, .ascii, .pixelSort:
            return nil  // handled specially
        }
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
                                   cache: GlassTextureCache) -> CIImage {
        let scale = params["inputScale"]?.doubleValue ?? 120
        let texture = cache.texture(for: extent)

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
                                    extent: CGRect) -> CIImage {
        let amount = params["amount"]?.doubleValue ?? 0.5
        let seed = params["seed"]?.doubleValue ?? 7
        let sliceH = max(params["sliceHeight"]?.doubleValue ?? 20, 2)
        guard amount > 0 else { return input }

        let src = input.clampedToExtent()
        var result = src

        // 1. RGB channel split (chromatic shift) proportional to amount.
        let shift = CGFloat(amount * 14)
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
            let dx = dir * CGFloat(seededRand.next01()) * 60 * CGFloat(amount)
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

    // MARK: - Pixel sort (approximation via directional streak blur on bright areas)

    private static func applyPixelSort(_ params: FilterParameters,
                                       to input: CIImage,
                                       extent: CGRect) -> CIImage {
        let amount = params["amount"]?.doubleValue ?? 0.5
        guard amount > 0 else { return input }
        // Motion blur creates the horizontal "sorted streak" look.
        guard let mb = CIFilter(name: "CIMotionBlur") else { return input }
        mb.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        mb.setValue((amount * 60) as NSNumber, forKey: "inputRadius")
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

/// Caches the frosted-glass displacement texture per extent so preview & export
/// use consistent glass cells. Not Sendable state — owned by the RenderEngine actor.
final class GlassTextureCache {
    private var cached: (size: CGSize, image: CIImage)?

    func texture(for extent: CGRect) -> CIImage {
        if let c = cached, c.size == extent.size { return c.image }
        // A lightly-scaled-up sharp noise gives strong local gradients — which is
        // what drives CIGlassDistortion's refraction. A heavy blur flattens the
        // gradients and the effect nearly vanishes, so keep the noise crisp and
        // just enlarge the cells with a mild pixellate for a "glass block" feel.
        let noise = (CIFilter.randomGenerator().outputImage ?? CIImage.empty())
            .cropped(to: extent)
        let px = CIFilter.pixellate()
        px.inputImage = noise
        px.scale = 6                      // small blocks → chunky glass cells
        px.center = CGPoint(x: extent.midX, y: extent.midY)
        let tex = (px.outputImage ?? noise).cropped(to: extent)
        cached = (extent.size, tex)
        return tex
    }
}
