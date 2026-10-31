import SwiftUI
import CoreGraphics

/// Live histogram of the current preview — the pro-app readout that shows
/// exposure/clipping at a glance. Recomputed off the main actor whenever the
/// preview changes; sampling is strided so cost stays trivial.
struct HistogramView: View {
    @Environment(FilteredDocument.self) private var document
    @State private var bins: HistogramBins?
    @State private var computeTask: Task<Void, Never>?
    @State private var mode: HistogramMode = .rgb

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Histogram").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $mode) {
                    Text("RGB").tag(HistogramMode.rgb)
                    Text("Luma").tag(HistogramMode.luma)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.25))
                if let bins {
                    HistogramChart(bins: bins, mode: mode)
                        .padding(4)
                } else {
                    Text("—").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .onChange(of: document.previewImage, initial: true) { _, img in
            recompute(img)
        }
    }

    private func recompute(_ image: NSImage?) {
        computeTask?.cancel()
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            bins = nil
            return
        }
        let boxed = SendableCGImage(cg)
        computeTask = Task {
            // Debounce: previews stream during slider drags.
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                HistogramBins.compute(from: boxed.cgImage)
            }.value
            guard !Task.isCancelled else { return }
            bins = result
        }
    }
}

enum HistogramMode: Hashable {
    case rgb, luma
}

/// 64-bin per-channel histogram (+ luminance), heights normalized 0...1.
struct HistogramBins: Sendable, Equatable {
    var r: [Double]
    var g: [Double]
    var b: [Double]
    var lum: [Double]

    static let binCount = 64

    static func compute(from cg: CGImage) -> HistogramBins? {
        guard let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }

        var r = [Double](repeating: 0, count: binCount)
        var g = [Double](repeating: 0, count: binCount)
        var b = [Double](repeating: 0, count: binCount)
        var lum = [Double](repeating: 0, count: binCount)

        // Stride so we sample at most ~120k pixels regardless of preview size.
        let total = cg.width * cg.height
        let step = max(1, Int((Double(total) / 120_000).squareRoot().rounded()))
        for y in Swift.stride(from: 0, to: cg.height, by: step) {
            for x in Swift.stride(from: 0, to: cg.width, by: step) {
                let o = y * bpr + x * bpp
                // Skip fully transparent pixels (canvas letterbox).
                if bpp >= 4 && ptr[o + 3] == 0 { continue }
                let rv = Int(ptr[o]), gv = Int(ptr[o + 1]), bv = Int(ptr[o + 2])
                r[rv * binCount / 256] += 1
                g[gv * binCount / 256] += 1
                b[bv * binCount / 256] += 1
                let l = Int(0.2126 * Double(rv) + 0.7152 * Double(gv) + 0.0722 * Double(bv))
                lum[min(l, 255) * binCount / 256] += 1
            }
        }
        // Normalize against the 98th-ish percentile so one dominant bin
        // (e.g. a black background) doesn't flatten the rest of the curve.
        let peak = max(percentile(r), percentile(g), percentile(b))
        guard peak > 0 else { return nil }
        let norm = { (v: Double) in min(v / peak, 1) }
        let lumPeak = max(percentile(lum), 1)
        return HistogramBins(r: r.map(norm), g: g.map(norm), b: b.map(norm),
                             lum: lum.map { min($0 / lumPeak, 1) })
    }

    private static func percentile(_ bins: [Double]) -> Double {
        let sorted = bins.sorted()
        let idx = min(Int(Double(sorted.count) * 0.98), sorted.count - 1)
        return sorted[idx]
    }
}

/// Translucent filled channel curves, screen-blended like every pro app.
/// Shared by the read-only panel and the Levels filter control.
struct HistogramChart: View {
    let bins: HistogramBins
    var mode: HistogramMode = .rgb

    var body: some View {
        Canvas { ctx, size in
            func draw(_ values: [Double], _ color: Color, opacity: Double) {
                var path = Path()
                let w = size.width / CGFloat(values.count)
                path.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * w + w / 2
                    let y = size.height * (1 - CGFloat(v))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(color.opacity(opacity)))
            }
            switch mode {
            case .rgb:
                ctx.blendMode = .screen
                draw(bins.r, .red, opacity: 0.5)
                draw(bins.g, .green, opacity: 0.5)
                draw(bins.b, .blue, opacity: 0.5)
            case .luma:
                draw(bins.lum, .white, opacity: 0.7)
            }
        }
    }
}
