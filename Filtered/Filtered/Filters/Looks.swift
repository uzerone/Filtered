import Foundation

/// A user-saved Look: a named snapshot of a filter stack, persisted across
/// launches. FilterInstance is Codable, so this serializes losslessly.
struct SavedLook: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var filters: [FilterInstance]
}

/// A "Look": a curated, one-click stack of filter layers — the fast path that
/// frontier filter apps lead with. Applying a Look inserts its filters as
/// ordinary filter layers (bottom-to-top), so everything stays editable.
struct LookPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let icon: String                 // SF Symbol
    /// Filters bottom-to-top, each with parameter overrides on top of defaults.
    let stack: [(kind: FilterKind, overrides: [String: FilterValue])]

    init(_ id: String, _ name: String, icon: String,
         _ stack: [(kind: FilterKind, overrides: [String: FilterValue])]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.stack = stack
    }

    /// Build the concrete FilterInstances for this look.
    func instances() -> [FilterInstance] {
        stack.map { entry in
            var params = entry.kind.defaultParameters()
            for (key, value) in entry.overrides { params.set(key, value) }
            return FilterInstance(kind: entry.kind, parameters: params)
        }
    }

    static let all: [LookPreset] = [
        LookPreset("newsprint", "Newsprint", icon: "newspaper", [
            (.colorControls, ["inputSaturation": .scalar(0), "inputContrast": .scalar(1.15)]),
            (.halftoneDots, ["inputWidth": .scalar(6)]),
            (.grain, ["grainAmount": .scalar(0.12)]),
        ]),
        LookPreset("riso", "Riso Print", icon: "printer", [
            (.posterize, ["inputLevels": .scalar(4)]),
            (.gradientMap, ["shadow": .color(RGBAColor(r: 0.10, g: 0.12, b: 0.45)),
                            "highlight": .color(RGBAColor(r: 1.0, g: 0.45, b: 0.55))]),
            (.grain, ["grainAmount": .scalar(0.18)]),
        ]),
        LookPreset("vhs", "VHS", icon: "video", [
            (.chromaticAberration, ["amount": .scalar(5)]),
            (.scanlines, ["spacing": .scalar(4), "intensity": .scalar(0.35)]),
            (.blur, ["inputRadius": .scalar(1.2)]),
            (.vignette, ["inputIntensity": .scalar(1.2), "inputRadius": .scalar(1.6)]),
        ]),
        LookPreset("cyberpunk", "Cyberpunk", icon: "bolt", [
            (.glitch, ["amount": .scalar(0.45), "seed": .scalar(7)]),
            (.chromaticAberration, ["amount": .scalar(8)]),
            (.bloom, ["inputRadius": .scalar(12), "inputIntensity": .scalar(1.2)]),
        ]),
        LookPreset("comicbook", "Comic Book", icon: "book", [
            (.comic, [:]),
            (.colorHalftone, ["inputWidth": .scalar(8)]),
        ]),
        LookPreset("pixelart", "Pixel Art", icon: "square.grid.3x3", [
            (.mosaic, ["inputScale": .scalar(16)]),
            (.posterize, ["inputLevels": .scalar(6)]),
        ]),
        LookPreset("dream", "Dream", icon: "cloud", [
            (.bloom, ["inputRadius": .scalar(20), "inputIntensity": .scalar(1.4)]),
            (.grain, ["grainAmount": .scalar(0.08)]),
            (.vignette, ["inputIntensity": .scalar(0.9), "inputRadius": .scalar(2.0)]),
        ]),
        LookPreset("silver", "Silver", icon: "circle.lefthalf.filled", [
            (.colorControls, ["inputSaturation": .scalar(0), "inputContrast": .scalar(1.1)]),
            (.sharpenLuminance, ["inputSharpness": .scalar(0.6)]),
            (.grain, ["grainAmount": .scalar(0.15)]),
            (.vignette, ["inputIntensity": .scalar(1.1), "inputRadius": .scalar(1.8)]),
        ]),
        LookPreset("goldenhour", "Golden Hour", icon: "sun.horizon", [
            (.whiteBalance, ["temp": .scalar(8200)]),
            (.vibrance, ["inputAmount": .scalar(0.25)]),
            (.highlightShadow, ["inputShadowAmount": .scalar(0.2)]),
            (.vignette, ["inputIntensity": .scalar(0.7), "inputRadius": .scalar(2.2)]),
        ]),
        LookPreset("polaroid", "Polaroid", icon: "camera", [
            (.filmInstant, [:]),
            (.grain, ["grainAmount": .scalar(0.1)]),
            (.vignette, ["inputIntensity": .scalar(0.9), "inputRadius": .scalar(1.9)]),
        ]),
        LookPreset("noir", "Noir", icon: "moon.stars", [
            (.filmNoir, [:]),
            (.grain, ["grainAmount": .scalar(0.16)]),
            (.vignette, ["inputIntensity": .scalar(1.4), "inputRadius": .scalar(1.6)]),
        ]),
        LookPreset("fadedfilm", "Faded Film", icon: "film", [
            (.filmFade, [:]),
            (.grain, ["grainAmount": .scalar(0.12)]),
            (.whiteBalance, ["temp": .scalar(7200)]),
        ]),
        LookPreset("tealorange", "Teal & Orange", icon: "circle.righthalf.filled", [
            (.splitTone, ["shadowColor": .color(RGBAColor(r: 0.05, g: 0.35, b: 0.45)),
                          "highlightColor": .color(RGBAColor(r: 1.0, g: 0.62, b: 0.28)),
                          "amount": .scalar(0.7)]),
            (.vibrance, ["inputAmount": .scalar(0.25)]),
            (.clarity, ["amount": .scalar(0.35)]),
        ]),
        LookPreset("cinematic", "Cinematic", icon: "movieclapper", [
            (.highlightShadow, ["inputShadowAmount": .scalar(0.25),
                                "inputHighlightAmount": .scalar(0.85)]),
            (.splitTone, ["shadowColor": .color(RGBAColor(r: 0.1, g: 0.2, b: 0.38)),
                          "highlightColor": .color(RGBAColor(r: 0.95, g: 0.8, b: 0.55)),
                          "amount": .scalar(0.5)]),
            (.vignette, ["inputIntensity": .scalar(1.0), "inputRadius": .scalar(2.0)]),
            (.grain, ["grainAmount": .scalar(0.07)]),
        ]),
        LookPreset("matte", "Matte", icon: "square.on.square.intersection.dashed", [
            (.levels, ["outBlack": .scalar(0.08), "outWhite": .scalar(0.97)]),
            (.colorControls, ["inputSaturation": .scalar(0.9)]),
            (.grain, ["grainAmount": .scalar(0.08)]),
        ]),
        LookPreset("lomo", "Lomo", icon: "camera.aperture", [
            (.colorControls, ["inputSaturation": .scalar(1.3), "inputContrast": .scalar(1.2)]),
            (.curves, ["y0": .scalar(0.04), "y1": .scalar(0.2), "y3": .scalar(0.82), "y4": .scalar(0.98)]),
            (.vignette, ["inputIntensity": .scalar(1.8), "inputRadius": .scalar(1.4)]),
            (.grain, ["grainAmount": .scalar(0.12)]),
        ]),
        LookPreset("sunburst", "Sunburst", icon: "sun.max", [
            (.whiteBalance, ["temp": .scalar(9000)]),
            (.vibrance, ["inputAmount": .scalar(0.35)]),
            (.bloom, ["inputRadius": .scalar(8), "inputIntensity": .scalar(0.7)]),
        ]),
        LookPreset("arctic", "Arctic", icon: "snowflake", [
            (.whiteBalance, ["temp": .scalar(4800)]),
            (.vibrance, ["inputAmount": .scalar(0.2)]),
            (.clarity, ["amount": .scalar(0.4)]),
        ]),
        LookPreset("bleach", "Bleach Bypass", icon: "drop.triangle", [
            (.colorControls, ["inputSaturation": .scalar(0.35), "inputContrast": .scalar(1.35)]),
            (.sharpenLuminance, ["inputSharpness": .scalar(0.5)]),
            (.grain, ["grainAmount": .scalar(0.14)]),
        ]),
        LookPreset("crisp", "Crisp Air", icon: "wind", [
            (.dehaze, ["amount": .scalar(0.55)]),
            (.clarity, ["amount": .scalar(0.45)]),
            (.vibrance, ["inputAmount": .scalar(0.15)]),
        ]),
    ]
}
