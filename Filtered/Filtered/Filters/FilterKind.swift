import Foundation

/// One tunable parameter of a filter. `key` is the exact Core Image input key.
struct FilterParamSpec: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        case scalar        // plain 0..1-ish number
        case pixelScalar   // size in pixels — multiplied by renderScale at render time
        case angle         // radians
        case color         // RGBAColor
        case center        // CIVector center point (pixel space)
        case bool
    }
    let key: String
    let label: String
    let kind: Kind
    let min: Double
    let max: Double
    let def: Double

    var id: String { key }
    var resolutionDependent: Bool { kind == .pixelScalar || kind == .center }

    /// Default FilterValue for this spec.
    var defaultValue: FilterValue {
        switch kind {
        case .scalar, .pixelScalar: return .scalar(def)
        case .angle: return .angle(def)
        case .color: return .color(.black)
        case .center: return .center(.zero)   // .zero => resolved to image center at render
        case .bool: return .bool(def != 0)
        }
    }
}

/// The family a filter belongs to — drives the grouped filter browser,
/// grouped by effect family for the filter browser.
enum FilterFamily: String, CaseIterable, Sendable, Identifiable {
    // Case order = display order in the picker: everyday photo adjustments
    // first, creative/stylistic effects after.
    case adjust, film, sharpen, halftone, pixelate, distort, stylize, glitch
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .adjust:   return "Adjust"
        case .film:     return "Film / Photo"
        case .sharpen:  return "Sharpen / Detail"
        case .halftone: return "Halftone"
        case .pixelate: return "Pixelate"
        case .distort:  return "Distort"
        case .stylize:  return "Stylize"
        case .glitch:   return "Glitch / Retro"
        }
    }
}

/// Every effect the app supports. Each maps to a verified real macOS CIFilter
/// (or a documented composite recipe handled specially in CIFilterFactory).
/// All CIFilter names and input keys were verified against the live macOS 26.5
/// Core Image runtime (CIFilter(name:).inputKeys).
enum FilterKind: String, CaseIterable, Sendable, Identifiable, Codable {
    // Halftone
    case halftoneCircle
    case halftoneDots
    case colorHalftone
    // Pixelate
    case mosaic
    case mosaicTiles
    // Distort
    case glass
    case bump
    case twirl
    // Stylize
    case grain          // composite recipe
    case gradientMap    // composite recipe
    case threshold
    case posterize
    case monochrome
    case invert
    case comic          // CIComicEffect
    case edges          // CIEdges
    case crystallize    // CICrystallize
    case pointillize    // CIPointillize
    case bloom          // CIBloom
    case ascii          // custom Metal kernel
    // Glitch / retro
    case glitch         // custom Metal kernel
    case chromaticAberration  // composite: channel offset
    case scanlines      // composite: line pattern multiply
    case pixelSort      // approximation via posterize+blur (custom-ish)
    // Adjust
    case colorControls
    case curves         // CIToneCurve, 5 points
    case exposure
    case gamma
    case hue
    case vignette
    case blur
    case whiteBalance   // CITemperatureAndTint (composite: neutral vector)
    case highlightShadow // CIHighlightShadowAdjust
    case vibrance       // CIVibrance
    case motionBlur     // CIMotionBlur
    case zoomBlur       // CIZoomBlur
    // Film / photo styles
    case sepia          // CISepiaTone
    case filmChrome     // CIPhotoEffectChrome
    case filmFade       // CIPhotoEffectFade
    case filmInstant    // CIPhotoEffectInstant
    case filmNoir       // CIPhotoEffectNoir
    case filmTonal      // CIPhotoEffectTonal
    case filmTransfer   // CIPhotoEffectTransfer
    // Distort (extra)
    case kaleidoscope   // CIKaleidoscope
    // Sharpen / detail
    case sharpenLuminance
    case unsharpMask
    case noiseReduction // CINoiseReduction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .halftoneCircle: return "Halftone Circle"
        case .halftoneDots:   return "Halftone Dots"
        case .colorHalftone:  return "Color Halftone"
        case .mosaic:         return "Mosaic"
        case .mosaicTiles:    return "Mosaic Tiles"
        case .glass:          return "Glass"
        case .bump:           return "Bump Lens"
        case .twirl:          return "Twirl"
        case .grain:          return "Grain"
        case .gradientMap:    return "Gradient Map"
        case .threshold:      return "Threshold"
        case .posterize:      return "Posterize"
        case .monochrome:     return "Monochrome"
        case .invert:         return "Invert"
        case .comic:          return "Comic"
        case .edges:          return "Edges"
        case .crystallize:    return "Crystallize"
        case .pointillize:    return "Pointillize"
        case .bloom:          return "Bloom"
        case .ascii:          return "ASCII Art"
        case .glitch:         return "Glitch"
        case .chromaticAberration: return "Chromatic Aberration"
        case .scanlines:      return "Scanlines"
        case .pixelSort:      return "Pixel Sort"
        case .colorControls:  return "Brightness / Contrast"
        case .curves:         return "Curves"
        case .exposure:       return "Exposure"
        case .gamma:          return "Gamma"
        case .hue:            return "Hue"
        case .vignette:       return "Vignette"
        case .blur:           return "Gaussian Blur"
        case .whiteBalance:   return "White Balance"
        case .highlightShadow: return "Highlights / Shadows"
        case .vibrance:       return "Vibrance"
        case .motionBlur:     return "Motion Blur"
        case .zoomBlur:       return "Zoom Blur"
        case .sepia:          return "Sepia"
        case .filmChrome:     return "Film · Chrome"
        case .filmFade:       return "Film · Fade"
        case .filmInstant:    return "Film · Instant"
        case .filmNoir:       return "Film · Noir"
        case .filmTonal:      return "Film · Tonal"
        case .filmTransfer:   return "Film · Transfer"
        case .kaleidoscope:   return "Kaleidoscope"
        case .sharpenLuminance: return "Sharpen"
        case .unsharpMask:    return "Unsharp Mask"
        case .noiseReduction: return "Noise Reduction"
        }
    }

    var family: FilterFamily {
        switch self {
        case .halftoneCircle, .halftoneDots, .colorHalftone: return .halftone
        case .mosaic, .mosaicTiles: return .pixelate
        case .glass, .bump, .twirl, .kaleidoscope: return .distort
        case .grain, .gradientMap, .threshold, .posterize, .monochrome, .invert,
             .comic, .edges, .crystallize, .pointillize, .bloom, .ascii: return .stylize
        case .glitch, .chromaticAberration, .scanlines, .pixelSort: return .glitch
        case .colorControls, .curves, .exposure, .gamma, .hue, .vignette, .blur,
             .whiteBalance, .highlightShadow, .vibrance, .motionBlur, .zoomBlur: return .adjust
        case .sepia, .filmChrome, .filmFade, .filmInstant, .filmNoir,
             .filmTonal, .filmTransfer: return .film
        case .sharpenLuminance, .unsharpMask, .noiseReduction: return .sharpen
        }
    }

    /// The parameter specs for this filter. Keys are exact CI input keys.
    var params: [FilterParamSpec] {
        switch self {
        case .halftoneCircle:
            return [
                .init(key: "inputWidth", label: "Dot Size", kind: .pixelScalar, min: 2, max: 50, def: 6),
                .init(key: "inputSharpness", label: "Sharpness", kind: .scalar, min: 0, max: 1, def: 0.7),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .halftoneDots:
            return [
                .init(key: "inputWidth", label: "Dot Pitch", kind: .pixelScalar, min: 2, max: 50, def: 8),
                .init(key: "inputAngle", label: "Angle", kind: .angle, min: -.pi, max: .pi, def: 0.5236),
                .init(key: "inputSharpness", label: "Sharpness", kind: .scalar, min: 0, max: 1, def: 0.9),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .colorHalftone:
            return [
                .init(key: "inputWidth", label: "Dot Size", kind: .pixelScalar, min: 2, max: 100, def: 6),
                .init(key: "inputAngle", label: "Angle", kind: .angle, min: -.pi, max: .pi, def: 0),
                .init(key: "inputSharpness", label: "Sharpness", kind: .scalar, min: 0, max: 1, def: 0.7),
                .init(key: "inputGCR", label: "GCR", kind: .scalar, min: 0, max: 1, def: 1),
                .init(key: "inputUCR", label: "UCR", kind: .scalar, min: 0, max: 1, def: 0.5),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .mosaic:
            return [
                .init(key: "inputScale", label: "Block Size", kind: .pixelScalar, min: 2, max: 200, def: 24),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .mosaicTiles:
            return [
                .init(key: "inputScale", label: "Tile Size", kind: .pixelScalar, min: 2, max: 200, def: 32),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .glass:
            return [
                .init(key: "inputScale", label: "Refraction", kind: .pixelScalar, min: 10, max: 500, def: 200),
            ]
        case .bump:
            return [
                .init(key: "inputRadius", label: "Radius", kind: .pixelScalar, min: 10, max: 1000, def: 300),
                .init(key: "inputScale", label: "Intensity", kind: .scalar, min: -1, max: 1, def: 0.5),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .twirl:
            return [
                .init(key: "inputRadius", label: "Radius", kind: .pixelScalar, min: 50, max: 1500, def: 600),
                .init(key: "inputAngle", label: "Angle", kind: .angle, min: -.pi * 3, max: .pi * 3, def: 3.14),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .grain:
            return [
                .init(key: "grainAmount", label: "Amount", kind: .scalar, min: 0, max: 1, def: 0.15),
            ]
        case .gradientMap:
            // Gradient defined by two colors; handled specially in the factory.
            return [
                .init(key: "shadow", label: "Shadow", kind: .color, min: 0, max: 0, def: 0),
                .init(key: "highlight", label: "Highlight", kind: .color, min: 0, max: 0, def: 0),
            ]
        case .threshold:
            return [
                .init(key: "inputThreshold", label: "Threshold", kind: .scalar, min: 0, max: 1, def: 0.5),
            ]
        case .posterize:
            return [
                .init(key: "inputLevels", label: "Levels", kind: .scalar, min: 2, max: 30, def: 6),
            ]
        case .monochrome:
            return [
                .init(key: "inputColor", label: "Color", kind: .color, min: 0, max: 0, def: 0),
                .init(key: "inputIntensity", label: "Intensity", kind: .scalar, min: 0, max: 1, def: 1),
            ]
        case .invert:
            return []
        case .comic:
            return []
        case .edges:
            return [
                .init(key: "inputIntensity", label: "Intensity", kind: .scalar, min: 0, max: 10, def: 3),
            ]
        case .crystallize:
            return [
                .init(key: "inputRadius", label: "Crystal Size", kind: .pixelScalar, min: 5, max: 150, def: 40),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .pointillize:
            return [
                .init(key: "inputRadius", label: "Dot Radius", kind: .pixelScalar, min: 2, max: 150, def: 20),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .bloom:
            return [
                .init(key: "inputRadius", label: "Radius", kind: .pixelScalar, min: 0, max: 100, def: 10),
                .init(key: "inputIntensity", label: "Intensity", kind: .scalar, min: 0, max: 2, def: 1),
            ]
        case .ascii:
            return [
                .init(key: "cellSize", label: "Cell Size", kind: .pixelScalar, min: 4, max: 40, def: 10),
            ]
        case .glitch:
            return [
                .init(key: "amount", label: "Intensity", kind: .scalar, min: 0, max: 1, def: 0.5),
                .init(key: "seed", label: "Seed", kind: .scalar, min: 0, max: 100, def: 7),
                .init(key: "sliceHeight", label: "Slice Height", kind: .pixelScalar, min: 2, max: 80, def: 20),
            ]
        case .chromaticAberration:
            return [
                .init(key: "amount", label: "Offset", kind: .pixelScalar, min: 0, max: 40, def: 6),
                .init(key: "angle", label: "Direction", kind: .angle, min: -.pi, max: .pi, def: 0),
            ]
        case .scanlines:
            return [
                .init(key: "spacing", label: "Line Spacing", kind: .pixelScalar, min: 2, max: 20, def: 3),
                .init(key: "intensity", label: "Intensity", kind: .scalar, min: 0, max: 1, def: 0.4),
            ]
        case .pixelSort:
            return [
                .init(key: "amount", label: "Intensity", kind: .scalar, min: 0, max: 1, def: 0.5),
                .init(key: "threshold", label: "Threshold", kind: .scalar, min: 0, max: 1, def: 0.5),
            ]
        case .colorControls:
            return [
                .init(key: "inputBrightness", label: "Brightness", kind: .scalar, min: -1, max: 1, def: 0),
                .init(key: "inputContrast", label: "Contrast", kind: .scalar, min: 0, max: 4, def: 1),
                .init(key: "inputSaturation", label: "Saturation", kind: .scalar, min: 0, max: 2, def: 1),
            ]
        case .curves:
            // Five tone-curve points at fixed x = 0, .25, .5, .75, 1; the
            // sliders move each point's OUTPUT. Defaults = identity.
            return [
                .init(key: "y0", label: "Shadows", kind: .scalar, min: 0, max: 1, def: 0),
                .init(key: "y1", label: "Darks", kind: .scalar, min: 0, max: 1, def: 0.25),
                .init(key: "y2", label: "Mids", kind: .scalar, min: 0, max: 1, def: 0.5),
                .init(key: "y3", label: "Lights", kind: .scalar, min: 0, max: 1, def: 0.75),
                .init(key: "y4", label: "Highlights", kind: .scalar, min: 0, max: 1, def: 1),
            ]
        case .exposure:
            return [
                .init(key: "inputEV", label: "Exposure", kind: .scalar, min: -4, max: 4, def: 0),
            ]
        case .gamma:
            return [
                .init(key: "inputPower", label: "Gamma", kind: .scalar, min: 0.1, max: 3, def: 1),
            ]
        case .hue:
            return [
                .init(key: "inputAngle", label: "Hue", kind: .angle, min: -.pi, max: .pi, def: 0),
            ]
        case .vignette:
            return [
                .init(key: "inputIntensity", label: "Intensity", kind: .scalar, min: 0, max: 2, def: 1),
                .init(key: "inputRadius", label: "Radius", kind: .scalar, min: 0, max: 4, def: 1.5),
            ]
        case .blur:
            return [
                .init(key: "inputRadius", label: "Radius", kind: .pixelScalar, min: 0, max: 50, def: 8),
            ]
        case .whiteBalance:
            // Kelvin slider: >6500 warms the image, <6500 cools it.
            return [
                .init(key: "temp", label: "Temperature", kind: .scalar, min: 2500, max: 12000, def: 6500),
                .init(key: "tint", label: "Tint", kind: .scalar, min: -100, max: 100, def: 0),
            ]
        case .highlightShadow:
            // Identity defaults: shadow 0 (no lift), highlight 1 (no pull).
            return [
                .init(key: "inputShadowAmount", label: "Shadows", kind: .scalar, min: -1, max: 1, def: 0),
                .init(key: "inputHighlightAmount", label: "Highlights", kind: .scalar, min: 0.3, max: 1, def: 1),
                .init(key: "inputRadius", label: "Radius", kind: .pixelScalar, min: 0, max: 25, def: 1.5),
            ]
        case .vibrance:
            return [
                .init(key: "inputAmount", label: "Vibrance", kind: .scalar, min: -1, max: 1, def: 0),
            ]
        case .motionBlur:
            return [
                .init(key: "inputRadius", label: "Length", kind: .pixelScalar, min: 0, max: 100, def: 20),
                .init(key: "inputAngle", label: "Direction", kind: .angle, min: -.pi, max: .pi, def: 0),
            ]
        case .zoomBlur:
            return [
                .init(key: "inputAmount", label: "Amount", kind: .pixelScalar, min: 0, max: 100, def: 20),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .sepia:
            return [
                .init(key: "inputIntensity", label: "Intensity", kind: .scalar, min: 0, max: 1, def: 0.8),
            ]
        case .filmChrome, .filmFade, .filmInstant, .filmNoir, .filmTonal, .filmTransfer:
            return []
        case .kaleidoscope:
            return [
                .init(key: "inputCount", label: "Segments", kind: .scalar, min: 2, max: 36, def: 6),
                .init(key: "inputAngle", label: "Angle", kind: .angle, min: -.pi, max: .pi, def: 0),
                .init(key: "inputCenter", label: "Center", kind: .center, min: 0, max: 0, def: 0),
            ]
        case .noiseReduction:
            return [
                .init(key: "inputNoiseLevel", label: "Noise Level", kind: .scalar, min: 0, max: 0.1, def: 0.02),
                .init(key: "inputSharpness", label: "Sharpness", kind: .scalar, min: 0, max: 2, def: 0.4),
            ]
        case .sharpenLuminance:
            return [
                .init(key: "inputSharpness", label: "Sharpness", kind: .scalar, min: 0, max: 2, def: 0.5),
                .init(key: "inputRadius", label: "Radius", kind: .scalar, min: 0, max: 20, def: 2),
            ]
        case .unsharpMask:
            return [
                .init(key: "inputRadius", label: "Radius", kind: .scalar, min: 0, max: 50, def: 2.5),
                .init(key: "inputIntensity", label: "Intensity", kind: .scalar, min: 0, max: 2, def: 0.6),
            ]
        }
    }

    /// Set of pixel-space keys to scale by renderScale on export.
    var pixelKeys: Set<String> {
        Set(params.filter { $0.kind == .pixelScalar }.map { $0.key })
    }

    /// Fresh default parameter bag.
    func defaultParameters() -> FilterParameters {
        var p = FilterParameters()
        for spec in params { p.set(spec.key, spec.defaultValue) }
        // Sensible non-zero color defaults for the two-color filters.
        if self == .gradientMap {
            p.set("shadow", .color(RGBAColor(r: 0.05, g: 0.02, b: 0.15)))
            p.set("highlight", .color(RGBAColor(r: 1.0, g: 0.85, b: 0.3)))
        }
        if self == .monochrome {
            p.set("inputColor", .color(RGBAColor(r: 0.4, g: 0.5, b: 0.7)))
        }
        return p
    }
}
