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

        // White balance: gray-world estimate. A red/blue channel imbalance in
        // the mean color reads as a temperature cast; correct it by declaring
        // the scene's neutral off-6500K so CITemperatureAndTint compensates.
        let cast = stats.meanB - stats.meanR
        if abs(cast) > 0.035 {
            // Image too blue (cast > 0) → declare neutral above 6500K → warms.
            let temp = clamp(6500 + cast * 9000, 5200, 8200)
            var p = FilterKind.whiteBalance.defaultParameters()
            p.set("temp", .scalar(temp.rounded()))
            instances.append(FilterInstance(kind: .whiteBalance, parameters: p))
        }

        // Exposure: pull mean luminance toward mid-gray (0.45).
        let ev = clamp(log2(0.45 / max(stats.meanLuma, 0.02)), -1.2, 1.2)
        if abs(ev) > 0.15 {
            var p = FilterKind.exposure.defaultParameters()
            p.set("inputEV", .scalar((ev * 100).rounded() / 100))
            instances.append(FilterInstance(kind: .exposure, parameters: p))
        }

        // Shadow lift / highlight recovery when a meaningful share of pixels
        // is crushed or blown (and exposure alone wouldn't fix both ends).
        let liftShadows = stats.pctCrushed > 0.12
        let pullHighlights = stats.pctBlown > 0.08
        if liftShadows || pullHighlights {
            var p = FilterKind.highlightShadow.defaultParameters()
            if liftShadows {
                p.set("inputShadowAmount", .scalar(clamp(stats.pctCrushed * 1.8, 0.15, 0.5)))
            }
            if pullHighlights {
                p.set("inputHighlightAmount", .scalar(clamp(1 - stats.pctBlown * 2.5, 0.6, 0.9)))
            }
            instances.append(FilterInstance(kind: .highlightShadow, parameters: p))
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
        var meanR: Double
        var meanB: Double
        /// Fraction of pixels with luma < 0.06 (crushed blacks).
        var pctCrushed: Double
        /// Fraction of pixels with luma > 0.96 (blown whites).
        var pctBlown: Double
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
        var rSum = 0.0, bSum = 0.0, crushed = 0.0, blown = 0.0
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let o = y * bpr + x * bpp
                let r = Double(ptr[o]) / 255, g = Double(ptr[o + 1]) / 255, b = Double(ptr[o + 2]) / 255
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let mx = max(r, g, b), mn = min(r, g, b)
                sum += lum; sumSq += lum * lum
                satSum += mx > 0.01 ? (mx - mn) / mx : 0
                rSum += r; bSum += b
                if lum < 0.06 { crushed += 1 }
                if lum > 0.96 { blown += 1 }
                n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        let variance = max(sumSq / n - mean * mean, 0)
        return Stats(meanLuma: mean, stdLuma: variance.squareRoot(), meanSat: satSum / n,
                     meanR: rSum / n, meanB: bSum / n,
                     pctCrushed: crushed / n, pctBlown: blown / n)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}
