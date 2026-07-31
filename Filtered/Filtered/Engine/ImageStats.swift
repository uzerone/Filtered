import Foundation
import CoreImage

/// Fast image statistics for Auto Enhance: analyze a tiny downscale of the
/// source and derive corrective, *editable* adjustment layers.
enum ImageStats {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Returns adjustment FilterInstances that would balance the image, or []
    /// if it already looks fine. Deterministic, tuned conservatively.
    static func autoEnhanceInstances(for image: CIImage) -> [FilterInstance] {
        guard let stats = analyze(image) else { return [] }
        var instances: [FilterInstance] = []

        // Exposure: pull mean luminance toward mid-gray (0.45).
        let ev = clamp(log2(0.45 / max(stats.meanLuma, 0.02)), -1.2, 1.2)
        if abs(ev) > 0.15 {
            var p = FilterKind.exposure.defaultParameters()
            p.set("inputEV", .scalar((ev * 100).rounded() / 100))
            instances.append(FilterInstance(kind: .exposure, parameters: p))
        }

        // Contrast: widen a flat histogram; Saturation: revive muted color.
        let contrast = clamp(0.22 / max(stats.stdLuma, 0.06), 1.0, 1.2)
        let saturation = stats.meanSat < 0.16
            ? clamp(0.18 / max(stats.meanSat, 0.05), 1.0, 1.25) : 1.0
        if contrast > 1.03 || saturation > 1.03 {
            var p = FilterKind.colorControls.defaultParameters()
            p.set("inputContrast", .scalar((contrast * 100).rounded() / 100))
            p.set("inputSaturation", .scalar((saturation * 100).rounded() / 100))
            instances.append(FilterInstance(kind: .colorControls, parameters: p))
        }
        return instances
    }

    private struct Stats {
        var meanLuma: Double
        var stdLuma: Double
        var meanSat: Double
    }

    private static func analyze(_ image: CIImage) -> Stats? {
        let e = image.extent
        guard e.width >= 1, e.height >= 1 else { return nil }
        let scale = 64.0 / Double(max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let se = small.extent.integral
        guard se.width >= 1, se.height >= 1,
              let cg = context.createCGImage(small, from: se),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        var sum = 0.0, sumSq = 0.0, satSum = 0.0, n = 0.0
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let o = y * bpr + x * bpp
                let r = Double(ptr[o]) / 255, g = Double(ptr[o + 1]) / 255, b = Double(ptr[o + 2]) / 255
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let mx = max(r, g, b), mn = min(r, g, b)
                sum += lum; sumSq += lum * lum
                satSum += mx > 0.01 ? (mx - mn) / mx : 0
                n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        let variance = max(sumSq / n - mean * mean, 0)
        return Stats(meanLuma: mean, stdLuma: variance.squareRoot(), meanSat: satSum / n)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}
