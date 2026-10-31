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
        case .levels:
            return applyLevels(params, to: input)
        case .dehaze:
            return applyDehaze(params, to: input)
        case .splitTone:
            return applySplitTone(params, to: input, extent: extent)
        case .clarity:
            return applyClarity(params, to: input, extent: extent)
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
            case .choice:
                break   // choice params only appear on specially-handled filters
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
             .chromaticAberration, .scanlines, .glitch, .ascii, .pixelSort,
             .levels, .dehaze, .splitTone, .clarity:
            return nil  // handled specially
        }
    }

    // MARK: - Levels (input range → gamma → output range, Photoshop semantics)

    private static func applyLevels(_ params: FilterParameters,
                                    to input: CIImage) -> CIImage {
        let inBlack = params["inBlack"]?.doubleValue ?? 0
        let inWhite = max(params["inWhite"]?.doubleValue ?? 1, inBlack + 0.01)
        let gamma = min(max(params["gamma"]?.doubleValue ?? 1, 0.1), 5)
        let outBlack = params["outBlack"]?.doubleValue ?? 0
        let outWhite = params["outWhite"]?.doubleValue ?? 1
        // Identity → free.
        if abs(inBlack) < 0.002, abs(inWhite - 1) < 0.002, abs(gamma - 1) < 0.005,
           abs(outBlack) < 0.002, abs(outWhite - 1) < 0.002 { return input }

        func matrix(_ image: CIImage, scale: Double, bias: Double) -> CIImage {
            let m = CIFilter.colorMatrix()
            m.inputImage = image
            m.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            m.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
            return m.outputImage ?? image
        }

        // Levels must operate on gamma-encoded (sRGB) values — the histogram
        // the user drags against bins encoded pixels, and Core Image's working
        // space is linear. Encode, apply, decode; otherwise a 0.25 black point
        // would crush everything below sRGB ~0.6 (verified: mid-gray → black).
        let encode = CIFilter.linearToSRGBToneCurve()
        encode.inputImage = input
        var img = encode.outputImage ?? input

        // 1. Remap [inBlack, inWhite] → [0, 1] and clip.
        let inScale = 1 / (inWhite - inBlack)
        img = matrix(img, scale: inScale, bias: -inBlack * inScale)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = img
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        img = clamp.outputImage ?? img
        // 2. Midtone gamma (slider > 1 brightens, like Photoshop).
        if abs(gamma - 1) > 0.005 {
            let g = CIFilter.gammaAdjust()
            g.inputImage = img
            g.power = Float(1 / gamma)
            img = g.outputImage ?? img
        }
        // 3. Compress into [outBlack, outWhite].
        if abs(outBlack) > 0.002 || abs(outWhite - 1) > 0.002 {
            img = matrix(img, scale: outWhite - outBlack, bias: outBlack)
        }

        let decode = CIFilter.sRGBToneCurveToLinear()
        decode.inputImage = img
        return decode.outputImage ?? img
    }

    // MARK: - Dehaze (contrast + blacks + gamma + vibrance recipe)

    private static func applyDehaze(_ params: FilterParameters,
                                    to input: CIImage) -> CIImage {
        let amount = min(max(params["amount"]?.doubleValue ?? 0.5, 0), 1)
        guard amount > 0.01 else { return input }
        // Haze reads as lifted blacks and flat contrast; pull both back.
        let cc = CIFilter.colorControls()
        cc.inputImage = input
        cc.contrast = Float(1 + 0.32 * amount)
        cc.saturation = Float(1 + 0.22 * amount)
        cc.brightness = Float(-0.04 * amount)
        var img = cc.outputImage ?? input
        let g = CIFilter.gammaAdjust()
        g.inputImage = img
        g.power = Float(1 + 0.3 * amount)
        img = g.outputImage ?? img
        let ex = CIFilter.exposureAdjust()
        ex.inputImage = img
        ex.ev = Float(0.18 * amount)
        return ex.outputImage ?? img
    }

    // MARK: - Split toning (tint shadows & highlights separately, Lightroom-style)

    private static func applySplitTone(_ params: FilterParameters,
                                       to input: CIImage,
                                       extent: CGRect) -> CIImage {
        var shadow = RGBAColor(r: 0.15, g: 0.35, b: 0.5)
        var highlight = RGBAColor(r: 1.0, g: 0.85, b: 0.55)
        if case .color(let c)? = params["shadowColor"] { shadow = c }
        if case .color(let c)? = params["highlightColor"] { highlight = c }
        let amount = min(max(params["amount"]?.doubleValue ?? 0.5, 0), 1)
        guard amount > 0.01 else { return input }

        func tinted(_ color: RGBAColor) -> CIImage {
            let solid = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: extent)
            let f = CIFilter.softLightBlendMode()
            f.inputImage = solid
            f.backgroundImage = input
            return (f.outputImage ?? input).cropped(to: extent)
        }

        // Luma decides which tint wins: dark pixels → shadow tint, bright →
        // highlight tint (mask luminance drives blendWithMask).
        let mono = CIFilter.photoEffectMono()
        mono.inputImage = input
        let luma = (mono.outputImage ?? input).cropped(to: extent)

        let mix = CIFilter.blendWithMask()
        mix.inputImage = tinted(highlight)
        mix.backgroundImage = tinted(shadow)
        mix.maskImage = luma
        let toned = (mix.outputImage ?? input).cropped(to: extent)

        // Wet/dry by amount.
        guard amount < 1 else { return toned }
        let fade = CIFilter.colorMatrix()
        fade.inputImage = toned
        fade.aVector = CIVector(x: 0, y: 0, z: 0, w: amount)
        let wet = fade.outputImage ?? toned
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = wet
        over.backgroundImage = input
        return (over.outputImage ?? input).cropped(to: extent)
    }

    // MARK: - Clarity (large-radius local contrast, Lightroom-style)

    private static func applyClarity(_ params: FilterParameters,
                                     to input: CIImage,
                                     extent: CGRect) -> CIImage {
        let amount = min(max(params["amount"]?.doubleValue ?? 0.5, 0), 1.5)
        guard amount > 0.01 else { return input }
        guard let f = CIFilter(name: "CIUnsharpMask") else { return input }
        f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        // Radius scales with image size so the effect reads as midtone punch,
        // not edge sharpening.
        f.setValue(max(extent.width, extent.height) / 40 as NSNumber, forKey: "inputRadius")
        f.setValue(amount * 0.7 as NSNumber, forKey: "inputIntensity")
        return (f.outputImage ?? input).cropped(to: extent)
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

    // MARK: - ASCII art (real character rendering via CoreText)

    /// Shared context for reading the downsampled cell grid.
    private static let sampleContext = CIContext(options: [.cacheIntermediates: false])

    /// Density ramps, darkest → brightest. Index = the "style" choice param.
    private static let asciiRamps: [[Character]] = [
        Array(" .:-=+*#%@"),          // Classic
        Array(" ░▒▓█"),               // Blocks
        Array(" @"),                  // @ Only
        Array(" 01"),                 // Binary
        [],                           // Random (chars picked per cell)
    ]
    private static let randomChars = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// True ASCII art: sample the image into a character grid, map each cell's
    /// luminance onto a density ramp, and rasterize the characters with
    /// CoreText. The glyph bitmap then acts as a mask over either flat white
    /// or the pixellated image colors.
    private static func applyASCII(_ params: FilterParameters,
                                   to input: CIImage,
                                   extent: CGRect) -> CIImage {
        var cell = max(params["cellSize"]?.doubleValue ?? 12, 4)
        let styleIdx = min(max(Int(params["style"]?.doubleValue ?? 0), 0), asciiRamps.count - 1)
        var colored = false
        if case .bool(let b)? = params["colored"] { colored = b }
        var inverted = false
        if case .bool(let b)? = params["inverted"] { inverted = b }
        var transparentBG = false
        if case .bool(let b)? = params["transparentBG"] { transparentBG = b }

        // Cap the grid so exports can't explode into millions of glyphs.
        cell = max(cell, max(extent.width, extent.height) / 1024)
        let wCells = max(Int(extent.width / cell), 1)
        let hCells = max(Int(extent.height / cell), 1)

        // 1. Downsample to one pixel per cell and read luminance (+ color).
        let sx = Double(wCells) / Double(extent.width)
        let sy = Double(hCells) / Double(extent.height)
        let small = input
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let gridRect = CGRect(x: 0, y: 0, width: wCells, height: hCells)
        guard let cg = sampleContext.createCGImage(small, from: gridRect,
                                                   format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return input }
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8

        // 2. Map cells to characters (CGImage row 0 = visual top).
        let ramp = asciiRamps[styleIdx]
        let isRandom = ramp.isEmpty
        var rows: [String] = []
        rows.reserveCapacity(hCells)
        for y in 0..<hCells {
            var row = String(); row.reserveCapacity(wCells)
            for x in 0..<wCells {
                let o = y * bpr + x * bpp
                var luma = 0.2126 * Double(ptr[o]) / 255
                       + 0.7152 * Double(ptr[o + 1]) / 255
                       + 0.0722 * Double(ptr[o + 2]) / 255
                if inverted { luma = 1 - luma }
                if isRandom {
                    // Stable per-cell character; density via draw/blank bands.
                    var rand = SeededRandom(seed: UInt64(y &* 92821 &+ x &+ 1))
                    let threshold = 0.18 + rand.next01() * 0.1
                    row.append(luma > threshold
                               ? randomChars[Int(rand.next() % UInt64(randomChars.count))]
                               : " ")
                } else {
                    let idx = min(Int(luma * Double(ramp.count)), ramp.count - 1)
                    row.append(ramp[idx])
                }
            }
            rows.append(row)
        }

        // 3. Rasterize the character grid with CoreText (white on black).
        let pxW = Int(extent.width.rounded(.up))
        let pxH = Int(extent.height.rounded(.up))
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return input }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))

        let font = CTFontCreateWithName("Menlo-Regular" as CFString, cell, nil)
        // Force each glyph's advance to exactly one cell for grid alignment.
        let probe = CTLineCreateWithAttributedString(
            NSAttributedString(string: "M", attributes: [.font: font]))
        let advance = max(CTLineGetTypographicBounds(probe, nil, nil, nil), 0.1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 1, alpha: 1),
            .kern: CGFloat(cell) - CGFloat(advance),
        ]
        for (r, rowString) in rows.enumerated() {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: rowString, attributes: attrs))
            // CG is bottom-up: row 0 draws at the top.
            let baselineY = CGFloat(pxH) - CGFloat(r + 1) * cell + cell * 0.22
            ctx.textPosition = CGPoint(x: 0, y: baselineY)
            CTLineDraw(line, ctx)
        }
        guard let maskCG = ctx.makeImage() else { return input }
        let mask = CIImage(cgImage: maskCG)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))

        // 4. Composite: glyph mask picks image colors (pixellated) or white.
        let colorSource: CIImage
        if colored {
            let px = CIFilter.pixellate()
            px.inputImage = input.clampedToExtent()
            px.scale = Float(cell)
            px.center = CGPoint(x: extent.midX, y: extent.midY)
            colorSource = (px.outputImage ?? input).cropped(to: extent)
        } else {
            colorSource = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        }
        let background = transparentBG
            ? CIImage.empty().cropped(to: extent)
            : CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = colorSource
        blend.backgroundImage = background
        blend.maskImage = mask
        return (blend.outputImage ?? input).cropped(to: extent)
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
