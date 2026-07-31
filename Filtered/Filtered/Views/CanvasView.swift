import SwiftUI
import UniformTypeIdentifiers

/// Center canvas: live preview with zoom & pan, drag-and-drop import, a
/// real-time alignment grid while moving text, and a before/after badge.
struct CanvasView: View {
    @Environment(FilteredDocument.self) private var document
    @Environment(\.displayScale) private var displayScale

    @State private var draggingLayerID: UUID?
    /// Which guide lines are currently "hit" by a snap (for highlighting).
    @State private var activeSnapX: CGFloat?   // normalized 0..1
    @State private var activeSnapY: CGFloat?
    /// Pan-gesture bookkeeping: pan value at gesture start.
    @State private var panStart: CGPoint?
    /// Pinch bookkeeping: zoom at gesture start.
    @State private var zoomStart: Double?
    @State private var isDropTargeted = false

    /// Snap targets in normalized canvas coords: edges, center, rule-of-thirds.
    private let snapPoints: [CGFloat] = [0, 1.0/3.0, 0.5, 2.0/3.0, 1]
    private let snapThreshold: CGFloat = 0.02   // ~2% of canvas

    var body: some View {
        GeometryReader { geo in
            let display = displayRect(in: geo.size)
            ZStack {
                // Recessed neutral well — a subtle radial darkening toward the
                // edges gives the canvas depth (a physical stage, not a flat fill).
                RadialGradient(
                    colors: [Color(white: 0.16), Color(white: 0.10)],
                    center: .center, startRadius: 40,
                    endRadius: max(geo.size.width, geo.size.height) * 0.7
                )

                if let preview = document.previewImage {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: display.width, height: display.height)
                        .position(x: display.midX, y: display.midY)
                        // A deeper, softer shadow reads as a real artboard lifted
                        // off the recessed well (Apple §12: bigger surface, thicker).
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                        // Pan by dragging the artboard when zoomed in.
                        .gesture(panGesture, including: document.canvasZoom > 1 ? .all : .subviews)
                } else {
                    emptyState
                        .frame(width: display.width, height: display.height)
                        .position(x: display.midX, y: display.midY)
                }

                // Real-time grid guide — only while dragging a text layer.
                if draggingLayerID != nil {
                    GridGuide(rect: display, activeX: activeSnapX, activeY: activeSnapY)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                // Text-layer drag handles.
                ForEach(document.layers.filter { $0.kind == .text && $0.isVisible }) { layer in
                    textHandle(layer, in: display)
                }

                // Before/after badge while comparing.
                if document.isComparingOriginal {
                    VStack {
                        Text("Original")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }

                // Zoom chip — appears when not at fit; click to reset.
                if document.canvasZoom != 1 {
                    VStack {
                        Spacer()
                        HStack {
                            Button {
                                withAnimation(Motion.quick) { document.zoomToFit() }
                            } label: {
                                Text("\(Int(document.canvasZoom * 100))%")
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(.ultraThinMaterial))
                            }
                            .buttonStyle(.plain)
                            .help("Zoom to fit")
                            .padding(.leading, 12).padding(.bottom, 10)
                            Spacer()
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            // Trackpad pinch zoom.
            .simultaneousGesture(magnifyGesture)
            // Double-click anywhere resets to fit.
            .onTapGesture(count: 2) {
                withAnimation(Motion.ui) { document.zoomToFit() }
            }
            // Drop an image file straight onto the canvas.
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                        .transition(.opacity)
                }
            }
            // Report the on-screen pixel width so previews render at display
            // resolution (not full canvas resolution) — the #1 speed fix.
            .onChange(of: display.width, initial: true) { _, w in
                let px = Double(w) * Double(displayScale)
                if abs(px - document.previewPixelWidth) > 1 {
                    document.previewPixelWidth = px
                    document.scheduleRender()
                }
            }
            .animation(Motion.quick, value: draggingLayerID != nil)
            .animation(Motion.quick, value: document.isComparingOriginal)
        }
    }

    // MARK: - Zoom & pan

    /// The artboard's on-screen rect: aspect-fit × zoom + pan.
    private func displayRect(in size: CGSize) -> CGRect {
        let base = fittedRect(in: size)
        let zoom = CGFloat(document.canvasZoom)
        let w = base.width * zoom
        let h = base.height * zoom
        let cx = size.width / 2 + CGFloat(document.canvasPanX)
        let cy = size.height / 2 + CGFloat(document.canvasPanY)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = document.canvasZoom }
                document.canvasZoom = (zoomStart ?? 1) * value.magnification
            }
            .onEnded { _ in zoomStart = nil }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if panStart == nil {
                    panStart = CGPoint(x: document.canvasPanX, y: document.canvasPanY)
                }
                guard let start = panStart else { return }
                document.canvasPanX = start.x + value.translation.width
                document.canvasPanY = start.y + value.translation.height
            }
            .onEnded { _ in panStart = nil }
    }

    // MARK: - Drag & drop import

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    var url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    guard let url else { return }
                    Task { @MainActor in
                        if let (image, size) = ImageImporter.load(url: url) {
                            document.setSourceImage(image, pixelSize: size)
                        }
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        if let (image, size) = ImageImporter.load(data: data) {
                            document.setSourceImage(image, pixelSize: size)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop an image here")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("⌘O Import · ⇧⌘V Paste · ⇧⌘T Add Text")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Text handles

    private func textHandle(_ layer: Layer, in rect: CGRect) -> some View {
        let x = rect.minX + rect.width * layer.position.x
        let y = rect.minY + rect.height * layer.position.y
        let selected = layer.id == document.selectedLayerID
        return Circle()
            .fill(selected ? Color.accentColor : Color.white.opacity(0.5))
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .position(x: x, y: y)
            .scaleEffect(selected ? 1.15 : 1)
            .animation(Motion.quick, value: selected)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        document.beginContinuousEdit("Move Text")
                        document.selectedLayerID = layer.id
                        withAnimation(Motion.quick) { draggingLayerID = layer.id }

                        // 1:1 tracking — the handle stays glued to the pointer.
                        var nx = (value.location.x - rect.minX) / rect.width
                        var ny = (value.location.y - rect.minY) / rect.height

                        // Snap to nearest guide within threshold.
                        let (sx, snappedX) = snap(nx)
                        let (sy, snappedY) = snap(ny)
                        nx = snappedX; ny = snappedY
                        activeSnapX = sx; activeSnapY = sy

                        layer.position = Point2D(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
                        document.scheduleRender()
                    }
                    .onEnded { _ in
                        document.endContinuousEdit()
                        withAnimation(Motion.quick) {
                            draggingLayerID = nil
                            activeSnapX = nil; activeSnapY = nil
                        }
                    }
            )
            .onTapGesture {
                withAnimation(Motion.quick) { document.selectedLayerID = layer.id }
            }
    }

    /// Snap a normalized coordinate to the nearest guide; returns the hit guide
    /// (for highlighting) and the possibly-adjusted value.
    private func snap(_ v: CGFloat) -> (CGFloat?, CGFloat) {
        var best: CGFloat?
        var bestDist = snapThreshold
        for p in snapPoints {
            let d = abs(v - p)
            if d < bestDist { bestDist = d; best = p }
        }
        return (best, best ?? v)
    }

    /// Aspect-fit the canvas into the available area with padding.
    private func fittedRect(in size: CGSize) -> CGRect {
        let pad: CGFloat = 32
        let avail = CGSize(width: max(size.width - pad * 2, 1),
                           height: max(size.height - pad * 2, 1))
        let aspect = CGFloat(document.canvas.aspectRatio)
        var w = avail.width
        var h = w / aspect
        if h > avail.height { h = avail.height; w = h * aspect }
        let x = (size.width - w) / 2
        let y = (size.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Rule-of-thirds + center alignment grid drawn over the canvas while dragging.
/// Active snap lines (center / thirds the handle is locked to) glow in accent.
private struct GridGuide: View {
    let rect: CGRect
    let activeX: CGFloat?     // normalized 0..1 or nil
    let activeY: CGFloat?

    private let thirds: [CGFloat] = [1.0/3.0, 2.0/3.0]

    var body: some View {
        ZStack {
            // Border.
            Rectangle()
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Rule-of-thirds lines.
            ForEach(thirds, id: \.self) { t in
                line(vertical: true, at: t, active: activeX == t)
                line(vertical: false, at: t, active: activeY == t)
            }
            // Center lines (highlight when snapped to 0.5).
            line(vertical: true, at: 0.5, active: activeX == 0.5, isCenter: true)
            line(vertical: false, at: 0.5, active: activeY == 0.5, isCenter: true)
        }
    }

    @ViewBuilder
    private func line(vertical: Bool, at t: CGFloat, active: Bool, isCenter: Bool = false) -> some View {
        let color: Color = active ? .accentColor
            : (isCenter ? .white.opacity(0.35) : .white.opacity(0.18))
        let w: CGFloat = active ? 1.5 : (isCenter ? 1 : 0.75)
        if vertical {
            Rectangle().fill(color)
                .frame(width: w, height: rect.height)
                .position(x: rect.minX + rect.width * t, y: rect.midY)
        } else {
            Rectangle().fill(color)
                .frame(width: rect.width, height: w)
                .position(x: rect.midX, y: rect.minY + rect.height * t)
        }
    }
}
