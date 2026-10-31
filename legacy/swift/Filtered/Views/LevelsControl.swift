import SwiftUI
import CoreGraphics

/// The Levels filter's interactive histogram: edit the image BY dragging the
/// histogram — black point, midtone (gamma), and white point markers under the
/// input histogram, plus an output range track. The histogram shows the
/// composite BELOW this layer (rendered small on demand), so it stays steady
/// while you drag instead of shifting under the pointer.
struct LevelsControl: View {
    @Environment(FilteredDocument.self) private var document
    let layerID: UUID
    @Binding var filter: FilterInstance

    @State private var bins: HistogramBins?
    @State private var computeTask: Task<Void, Never>?
    @State private var dragging = false

    // MARK: parameter access

    private func value(_ key: String, _ def: Double) -> Double {
        filter.parameters[key]?.doubleValue ?? def
    }
    private func set(_ key: String, _ v: Double) {
        if !dragging {
            dragging = true
            document.beginContinuousEdit("Levels")
        }
        filter.parameters.set(key, .scalar(v))
        document.scheduleRender()
    }
    private func endDrag() {
        dragging = false
        document.endContinuousEdit()
    }

    private var inBlack: Double { value("inBlack", 0) }
    private var inWhite: Double { value("inWhite", 1) }
    private var gamma: Double { value("gamma", 1) }
    private var outBlack: Double { value("outBlack", 0) }
    private var outWhite: Double { value("outWhite", 1) }

    /// Gamma ↔ thumb position between the black/white markers.
    /// t = 0.5 → 1.0; left of center brightens (γ > 1), Photoshop-style.
    private var gammaT: Double { (1 - log(gamma) / log(3)) / 2 }
    private func gammaFrom(t: Double) -> Double {
        pow(3, 1 - 2 * min(max(t, 0.02), 0.98))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Input Levels").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.25))
                    if let bins {
                        HistogramChart(bins: bins, mode: .rgb).padding(4)
                    }
                    // Shade the clipped ranges.
                    GeometryReader { geo in
                        let w = geo.size.width
                        Rectangle().fill(.black.opacity(0.45))
                            .frame(width: max(w * inBlack, 0))
                        Rectangle().fill(.black.opacity(0.45))
                            .frame(width: max(w * (1 - inWhite), 0))
                            .offset(x: w * inWhite)
                    }
                    .allowsHitTesting(false)
                }
                .frame(height: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                // Input markers: black ▲, gamma ◆, white ▲.
                GeometryReader { geo in
                    let w = geo.size.width
                    let gammaX = inBlack + gammaT * (inWhite - inBlack)
                    marker("arrowtriangle.up.fill", color: .primary, x: inBlack * w) { nx in
                        set("inBlack", min(max(nx, 0), inWhite - 0.05))
                    }
                    marker("diamond.fill", color: .secondary, x: gammaX * w) { nx in
                        let span = max(inWhite - inBlack, 0.001)
                        set("gamma", gammaFrom(t: (nx - inBlack) / span))
                    }
                    marker("arrowtriangle.up.fill", color: .primary, x: inWhite * w,
                           filledWhite: true) { nx in
                        set("inWhite", max(min(nx, 1), inBlack + 0.05))
                    }
                }
                .frame(height: 18)
            }

            HStack {
                readout("Black", inBlack, "%.2f")
                Spacer()
                readout("Midtones", gamma, "%.2f")
                Spacer()
                readout("White", inWhite, "%.2f")
            }

            Text("Output Levels").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                GeometryReader { geo in
                    let w = geo.size.width
                    marker("arrowtriangle.up.fill", color: .primary, x: outBlack * w) { nx in
                        set("outBlack", min(max(nx, 0), outWhite - 0.05))
                    }
                    marker("arrowtriangle.up.fill", color: .primary, x: outWhite * w,
                           filledWhite: true) { nx in
                        set("outWhite", max(min(nx, 1), outBlack + 0.05))
                    }
                }
                .frame(height: 18)
            }

            HStack {
                readout("Out Black", outBlack, "%.2f")
                Spacer()
                readout("Out White", outWhite, "%.2f")
                Spacer()
                Button("Reset") {
                    document.checkpoint("Reset Levels")
                    for (key, def) in [("inBlack", 0.0), ("gamma", 1.0), ("inWhite", 1.0),
                                       ("outBlack", 0.0), ("outWhite", 1.0)] {
                        filter.parameters.set(key, .scalar(def))
                    }
                    document.scheduleRender()
                }
                .controlSize(.small)
            }
        }
        .onChange(of: document.previewImage, initial: true) { _, _ in
            recomputeInputHistogram()
        }
    }

    private func readout(_ label: String, _ v: Double, _ fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(String(format: fmt, v)).font(.caption).monospacedDigit()
        }
    }

    /// A draggable marker thumb positioned at `x` (points) on its track.
    private func marker(_ symbol: String, color: Color, x: CGFloat,
                        filledWhite: Bool = false,
                        onDrag: @escaping (Double) -> Void) -> some View {
        GeometryReader { geo in
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(filledWhite ? Color.white : color)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .position(x: min(max(x, 6), geo.size.width - 6), y: 8)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            onDrag(Double(min(max(v.location.x / geo.size.width, 0), 1)))
                        }
                        .onEnded { _ in endDrag() }
                )
        }
    }

    /// Histogram of the composite BELOW this Levels layer: render the stack
    /// truncated at this layer at thumbnail size, then bin it.
    private func recomputeInputHistogram() {
        computeTask?.cancel()
        guard document.baseImage != nil else { bins = nil; return }
        let scale = min(256.0 / Double(max(document.canvas.width, 1)), 1)
        let request = document.makeRenderRequest(renderScale: scale, upTo: layerID)
        computeTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            guard let cg = await RenderEngine.shared.render(request)?.cgImage else { return }
            let boxed = SendableCGImage(cg)
            let result = await Task.detached(priority: .utility) {
                HistogramBins.compute(from: boxed.cgImage)
            }.value
            guard !Task.isCancelled else { return }
            bins = result
        }
    }
}
