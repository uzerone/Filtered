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
        // Crop mode replaces the whole canvas with the crop workspace.
        if document.isCropping, let img = document.cropPreviewImage {
            CropOverlay(image: img,
                        initialCrop: document.canvas.cropRect,
                        onApply: { document.applyCrop($0) },
                        onCancel: { document.exitCropMode() })
        } else {
            editorCanvas
        }
    }

    private var editorCanvas: some View {
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

                // Text-layer drag handles (includes text inside visible groups).
                ForEach(document.visibleTextLayers) { layer in
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

                // Animation transport — only for animated sources (GIF/APNG).
                if document.isAnimated {
                    VStack {
                        Spacer()
                        AnimationTransportBar()
                            .padding(.bottom, 12)
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
                        ImageImporter.importFile(url: url, into: document)
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        ImageImporter.importData(data, into: document)
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
                        document.setPrimarySelection(layer.id)
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
                withAnimation(Motion.quick) { document.selectLayer(layer.id) }
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

/// Play/pause + frame scrubber for animated sources. Every frame renders
/// through the live filter stack, so you preview the final motion.
private struct AnimationTransportBar: View {
    @Environment(FilteredDocument.self) private var document

    var body: some View {
        HStack(spacing: 10) {
            Button {
                document.togglePlayback()
            } label: {
                Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(document.isPlaying ? "Pause" : "Play")

            Slider(value: Binding(
                get: { Double(document.currentFrameIndex) },
                set: { v in
                    document.stopPlayback()
                    document.showFrame(Int(v.rounded()))
                }), in: 0...Double(max(document.frameCount - 1, 1)))
                .controlSize(.small)
                .frame(width: 180)

            Text("\(document.currentFrameIndex + 1)/\(document.frameCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
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

// MARK: - Crop workspace

/// Full-canvas crop UI: the oriented source with a draggable/resizable crop
/// rectangle, aspect presets, and Apply/Cancel. Works in top-left screen
/// coordinates internally; converts to CI (bottom-left) space on apply.
private struct CropOverlay: View {
    let image: NSImage
    let initialCrop: CGRect?          // CI-space normalized, or nil
    let onApply: (CGRect?) -> Void
    let onCancel: () -> Void

    /// Screen-space normalized crop (origin top-left), 0..1.
    @State private var crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var didInit = false
    @State private var dragStart: CGRect?
    @State private var aspect: Double? = nil     // nil = free

    private let minSize: CGFloat = 0.05
    private let aspects: [(String, Double?)] = [
        ("Free", nil), ("1:1", 1), ("4:5", 4.0/5.0), ("3:2", 3.0/2.0),
        ("16:9", 16.0/9.0), ("9:16", 9.0/16.0),
    ]

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedRect(in: geo.size)
            ZStack {
                Color(white: 0.10)

                Image(nsImage: image)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)

                // Dim everything outside the crop.
                CropShade(imageRect: fitted, crop: crop)
                    .allowsHitTesting(false)

                // Crop rectangle + handles.
                cropRectangle(in: fitted)

                // Controls.
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Picker("", selection: $aspect) {
                            ForEach(aspects, id: \.0) { name, value in
                                Text(name).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 320)
                        .onChange(of: aspect) { _, a in
                            if let a { applyAspect(a) }
                        }
                        Button("Reset") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                        Button("Cancel") { onCancel() }
                            .keyboardShortcut(.cancelAction)
                        Button("Apply") { apply() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                }
            }
            .onAppear {
                guard !didInit else { return }
                didInit = true
                if let ci = initialCrop {
                    // CI bottom-left -> screen top-left.
                    crop = CGRect(x: ci.minX, y: 1 - ci.minY - ci.height,
                                  width: ci.width, height: ci.height)
                }
            }
        }
    }

    private func apply() {
        // Screen top-left -> CI bottom-left.
        let ci = CGRect(x: crop.minX, y: 1 - crop.minY - crop.height,
                        width: crop.width, height: crop.height)
        onApply(ci)
    }

    private func applyAspect(_ a: Double) {
        // Keep the center; fit the largest rect with the aspect inside 0..1
        // around the current crop, using image-space aspect correction.
        let imgAspect = image.size.width / image.size.height
        // Desired w/h in normalized units so that (w*imgW)/(h*imgH) == a.
        let normAspect = a / Double(imgAspect)
        var w = crop.width
        var h = w / CGFloat(normAspect)
        if h > 1 { h = 1; w = h * CGFloat(normAspect) }
        if w > 1 { w = 1; h = w / CGFloat(normAspect) }
        let cx = crop.midX, cy = crop.midY
        var r = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
        r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
        crop = r
    }

    private func cropRectangle(in fitted: CGRect) -> some View {
        let r = CGRect(x: fitted.minX + crop.minX * fitted.width,
                       y: fitted.minY + crop.minY * fitted.height,
                       width: crop.width * fitted.width,
                       height: crop.height * fitted.height)
        return ZStack {
            // Border + thirds.
            Rectangle().stroke(Color.white, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
            ForEach([1.0 / 3.0, 2.0 / 3.0], id: \.self) { t in
                Rectangle().fill(Color.white.opacity(0.25))
                    .frame(width: 0.75, height: r.height)
                    .position(x: r.minX + r.width * t, y: r.midY)
                Rectangle().fill(Color.white.opacity(0.25))
                    .frame(width: r.width, height: 0.75)
                    .position(x: r.midX, y: r.minY + r.height * t)
            }
            // Move (drag the interior).
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: max(r.width - 28, 1), height: max(r.height - 28, 1))
                .position(x: r.midX, y: r.midY)
                .gesture(moveGesture(in: fitted))
            // Corner handles.
            ForEach(0..<4, id: \.self) { corner in
                let cx = (corner % 2 == 0) ? r.minX : r.maxX
                let cy = (corner < 2) ? r.minY : r.maxY
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                    .position(x: cx, y: cy)
                    .gesture(resizeGesture(corner: corner, in: fitted))
            }
        }
    }

    private func moveGesture(in fitted: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = crop }
                guard let start = dragStart else { return }
                var r = start
                r.origin.x += value.translation.width / fitted.width
                r.origin.y += value.translation.height / fitted.height
                r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
                r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
                crop = r
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(corner: Int, in fitted: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = crop }
                guard let start = dragStart else { return }
                let dx = value.translation.width / fitted.width
                let dy = value.translation.height / fitted.height
                var minX = start.minX, maxX = start.maxX
                var minY = start.minY, maxY = start.maxY
                if corner % 2 == 0 { minX = min(max(start.minX + dx, 0), maxX - minSize) }
                else { maxX = max(min(start.maxX + dx, 1), minX + minSize) }
                if corner < 2 { minY = min(max(start.minY + dy, 0), maxY - minSize) }
                else { maxY = max(min(start.maxY + dy, 1), minY + minSize) }
                var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                // Aspect lock: derive height from width around the anchored corner.
                if let a = aspect {
                    let imgAspect = image.size.width / image.size.height
                    let normAspect = CGFloat(a) / imgAspect
                    let h = r.width / normAspect
                    if corner < 2 { r.origin.y = maxY - h }   // top corners anchor bottom
                    r.size.height = h
                    if r.minY < 0 || r.maxY > 1 {
                        // Clamp by height instead.
                        let hClamped = min(r.height, corner < 2 ? maxY : 1 - r.minY)
                        r.size.height = hClamped
                        r.size.width = hClamped * normAspect
                        if corner % 2 == 0 { r.origin.x = maxX - r.width }
                        if corner < 2 { r.origin.y = maxY - r.height }
                    }
                }
                crop = r
            }
            .onEnded { _ in dragStart = nil }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let pad: CGFloat = 48
        let avail = CGSize(width: max(size.width - pad * 2, 1),
                           height: max(size.height - pad * 2, 1))
        let aspect = image.size.width / max(image.size.height, 1)
        var w = avail.width
        var h = w / aspect
        if h > avail.height { h = avail.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// Dims the area outside the crop rect.
private struct CropShade: View {
    let imageRect: CGRect
    let crop: CGRect

    var body: some View {
        let r = CGRect(x: imageRect.minX + crop.minX * imageRect.width,
                       y: imageRect.minY + crop.minY * imageRect.height,
                       width: crop.width * imageRect.width,
                       height: crop.height * imageRect.height)
        Canvas { ctx, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(r)
            ctx.fill(path, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
        }
    }
}
