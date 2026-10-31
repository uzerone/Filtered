import Foundation
import Observation

/// User-controlled canvas: pixel dimensions, background, image placement, DPI.
/// @MainActor @Observable — pure UI/model state, never crosses the render actor.
@MainActor
@Observable
final class CanvasSettings {
    var width: Int
    var height: Int
    var background: CanvasBackground
    var imageFit: ImageFit
    var dpi: Int

    /// Source-image orientation: quarter-turns clockwise (0–3), mirror first.
    var orientationQuarters: Int = 0
    var flippedH: Bool = false
    /// Subject cutout (Vision mask) is active.
    var backgroundRemoved: Bool = false
    /// Normalized crop of the oriented source (CI coords, origin bottom-left).
    /// Nil = uncropped.
    var cropRect: CGRect?

    init(width: Int = 1080,
         height: Int = 1080,
         background: CanvasBackground = .solid(.black),
         imageFit: ImageFit = .fit,
         dpi: Int = 72) {
        self.width = width
        self.height = height
        self.background = background
        self.imageFit = imageFit
        self.dpi = dpi
    }

    var pixelSize: Size2D { Size2D(width: Double(width), height: Double(height)) }
    var aspectRatio: Double { height == 0 ? 1 : Double(width) / Double(height) }

    /// Common presets shown in the canvas-size control.
    struct Preset: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let width: Int
        let height: Int
    }

    /// Preset groups shown in the canvas-size menu.
    struct PresetGroup: Identifiable {
        let id = UUID()
        let title: String
        let presets: [Preset]
    }

    static let presetGroups: [PresetGroup] = [
        .init(title: "Square", presets: [
            .init(name: "Square 1080", width: 1080, height: 1080),
            .init(name: "Square 2K", width: 2048, height: 2048),
            .init(name: "Square 4K", width: 4096, height: 4096),
        ]),
        .init(title: "Standard", presets: [
            .init(name: "HD 720p", width: 1280, height: 720),
            .init(name: "Full HD 1080p", width: 1920, height: 1080),
            .init(name: "2K (QHD)", width: 2560, height: 1440),
            .init(name: "4K (UHD)", width: 3840, height: 2160),
            .init(name: "8K (UHD)", width: 7680, height: 4320),
        ]),
        .init(title: "Social Media", presets: [
            .init(name: "Portrait 4:5", width: 1080, height: 1350),
            .init(name: "Story 9:16", width: 1080, height: 1920),
            .init(name: "Landscape 16:9", width: 1920, height: 1080),
            .init(name: "Cover 3:2", width: 1620, height: 1080),
        ]),
        .init(title: "Print", presets: [
            .init(name: "A4 @150", width: 1240, height: 1754),
            .init(name: "A4 @300", width: 2480, height: 3508),
            .init(name: "A3 @300", width: 3508, height: 4961),
        ]),
    ]

    /// Flat list (kept for compatibility).
    static var presets: [Preset] { presetGroups.flatMap(\.presets) }

    func apply(_ preset: Preset) {
        width = preset.width
        height = preset.height
    }
}
