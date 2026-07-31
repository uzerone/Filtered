import Foundation
import Observation
import CoreImage
import AppKit

/// The central document. @MainActor @Observable — owns canvas, layers, selection,
/// and the source image. All UI reads/writes this; the render engine only ever
/// receives a Sendable RenderRequest snapshot built here on the main actor.
@MainActor
@Observable
final class FilteredDocument {
    var canvas = CanvasSettings()
    var layers: [Layer] = []
    var selectedLayerID: UUID?

    /// The .ftrd file this document is saved to (nil = never saved).
    var projectURL: URL?
    /// Display name for the window title.
    var projectName: String { projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }

    /// True when there are edits not yet saved to the project file.
    var isDirty = false

    /// While true, the preview renders with all filter layers bypassed —
    /// the press-and-hold "before/after" compare.
    var isComparingOriginal = false {
        didSet { if isComparingOriginal != oldValue { scheduleRender() } }
    }

    /// The filter layer whose DETAIL settings are open (entered via double-click).
    /// While nil (or not matching the selection), a selected filter layer just
    /// shows the "add filter" picker so the user can keep stacking filters.
    var editingFilterLayerID: UUID?

    /// True when the selected layer is a filter layer opened for detail editing.
    var isEditingFilterDetail: Bool {
        guard let sel = selectedLayerID, sel == editingFilterLayerID else { return false }
        return selectedLayer?.kind == .filter
    }

    /// Single-click: select a layer (no detail). Keeps the add-filter picker up
    /// for image/text/unopened-filter layers.
    func selectLayer(_ id: UUID) {
        selectedLayerID = id
        editingFilterLayerID = nil
    }

    /// Double-click a filter layer: open its detail parameters.
    func openFilterDetail(_ id: UUID) {
        selectedLayerID = id
        editingFilterLayerID = id
    }

    func closeFilterDetail() {
        editingFilterLayerID = nil
    }

    /// The imported source image at native resolution (kept for full-res export).
    var sourceImage: CIImage?
    var sourcePixelSize: Size2D?

    /// Live preview output shown in the canvas view.
    var previewImage: NSImage?
    var isRendering = false

    // UI signal flags toggled from menu commands.
    var requestImport = false
    var requestExport = false

    @ObservationIgnored private var renderTask: Task<Void, Never>?

    /// The canvas view reports its on-screen pixel width here (fitted width ×
    /// backing scale × zoom) so previews render at display resolution instead
    /// of full canvas resolution. 0 = unknown → render at 1:1.
    @ObservationIgnored var previewPixelWidth: Double = 0

    /// Preview render scale: never upscale past 1 (export always renders 1+).
    private var previewScale: Double {
        guard previewPixelWidth > 0, canvas.width > 0 else { return 1 }
        return min(1, previewPixelWidth / Double(canvas.width))
    }

    var selectedLayer: Layer? {
        guard let id = selectedLayerID else { return nil }
        return layers.first { $0.id == id }
    }

    var baseImage: CIImage? { sourceImage }

    // MARK: - Canvas viewport (zoom & pan)

    var canvasZoom: Double = 1 {
        didSet {
            let clamped = min(max(canvasZoom, 0.25), 8)
            if canvasZoom != clamped { canvasZoom = clamped }
            if canvasZoom == 1 { canvasPanX = 0; canvasPanY = 0 }
        }
    }
    var canvasPanX: Double = 0
    var canvasPanY: Double = 0

    func zoomIn()  { canvasZoom = min(canvasZoom * 1.25, 8) }
    func zoomOut() { canvasZoom = max(canvasZoom / 1.25, 0.25) }
    func zoomToFit() { canvasZoom = 1; canvasPanX = 0; canvasPanY = 0 }

    // MARK: - Document lifecycle

    func newCanvas() {
        layers = []
        sourceImage = nil
        sourcePixelSize = nil
        previewImage = nil
        selectedLayerID = nil
        editingFilterLayerID = nil
        projectURL = nil
        subjectMask = nil
        isDirty = false
        canvas = CanvasSettings()
        clearUndoHistory()
        scheduleRender()
    }

    func setSourceImage(_ image: CIImage, pixelSize: Size2D) {
        sourceImage = image
        sourcePixelSize = pixelSize
        // A new image invalidates the old mask and orientation.
        subjectMask = nil
        canvas.backgroundRemoved = false
        canvas.orientationQuarters = 0
        canvas.flippedH = false
        canvas.cropRect = nil
        // Ensure there is an image layer at the bottom.
        if !layers.contains(where: { $0.kind == .image }) {
            let layer = Layer.imageLayer()
            layers.insert(layer, at: 0)
            selectedLayerID = layer.id
        }
        // Match canvas to image aspect on first import if canvas is default square.
        if canvas.width == 1080 && canvas.height == 1080 {
            canvas.width = Int(pixelSize.width)
            canvas.height = Int(pixelSize.height)
        }
        isDirty = true
        scheduleRender()
    }

    // MARK: - Layer ops (each checkpoints undo state first)

    func addTextLayer() {
        checkpoint("Add Text")
        let layer = Layer.textLayer()
        layers.append(layer)
        selectedLayerID = layer.id
        scheduleRender()
    }

    /// Add a filter as its own adjustment layer, inserted directly ABOVE the
    /// currently selected layer (so it affects everything at/below the selection),
    /// or on top of the stack if nothing is selected.
    func addFilter(_ kind: FilterKind) {
        checkpoint("Add \(kind.displayName)")
        let layer = Layer.filterLayer(kind)
        layers.insert(layer, at: insertionIndex())
        selectedLayerID = layer.id
        scheduleRender()
    }

    /// Apply a Look: insert its whole filter stack as editable filter layers.
    func applyLook(_ look: LookPreset) {
        checkpoint("Apply \(look.name)")
        var idx = insertionIndex()
        var lastID: UUID?
        for instance in look.instances() {
            let layer = Layer(name: instance.kind.displayName, kind: .filter, filter: instance)
            layers.insert(layer, at: idx)
            lastID = layer.id
            idx += 1
        }
        if let lastID { selectedLayerID = lastID }
        editingFilterLayerID = nil
        scheduleRender()
    }

    /// Where a new filter layer goes: just above the selection, else on top.
    private func insertionIndex() -> Int {
        if let sel = selectedLayerID,
           let idx = layers.firstIndex(where: { $0.id == sel }) {
            return idx + 1
        }
        return layers.count
    }

    // MARK: - Image operations (rotate / flip / subject cutout)

    /// Composing a screen-space op onto (quarters, flippedH) where the render
    /// applies mirror FIRST, then rotation.
    func rotateClockwise() {
        checkpoint("Rotate")
        canvas.orientationQuarters = (canvas.orientationQuarters + 1) % 4
        scheduleRender()
    }

    func rotateCounterclockwise() {
        checkpoint("Rotate")
        canvas.orientationQuarters = (canvas.orientationQuarters + 3) % 4
        scheduleRender()
    }

    func flipHorizontal() {
        checkpoint("Flip Horizontal")
        // H · R(q) · F(f) = R(-q) · H · F(f): negate rotation, toggle mirror.
        canvas.orientationQuarters = (4 - canvas.orientationQuarters) % 4
        canvas.flippedH.toggle()
        scheduleRender()
    }

    func flipVertical() {
        checkpoint("Flip Vertical")
        // V = H · R(2): compose both.
        canvas.orientationQuarters = (4 - ((canvas.orientationQuarters + 2) % 4)) % 4
        canvas.flippedH.toggle()
        scheduleRender()
    }

    /// The Vision subject mask (source resolution). Cached, not snapshotted —
    /// recomputed on demand/load when `canvas.backgroundRemoved` is set.
    @ObservationIgnored private var subjectMask: SendableCIImage?
    /// True while the segmentation model is running.
    var isComputingMask = false

    /// One-click background removal. Computes the mask off-main, then enables
    /// the cutout (undoable via the flag; the mask itself stays cached).
    func removeBackground() {
        guard let source = sourceImage, !isComputingMask else { return }
        isComputingMask = true
        Task { [weak self] in
            let mask = await SubjectMask.compute(for: source)
            guard let self else { return }
            self.isComputingMask = false
            guard let mask else {
                let alert = NSAlert()
                alert.messageText = "No subject found"
                alert.informativeText = "Couldn't detect a foreground subject in this image."
                alert.runModal()
                return
            }
            self.subjectMask = mask
            self.checkpoint("Cut Out Subject")
            self.canvas.backgroundRemoved = true
            self.scheduleRender()
        }
    }

    func restoreBackground() {
        checkpoint("Restore Background")
        canvas.backgroundRemoved = false
        scheduleRender()
    }

    /// Recompute the mask if a loaded/undone state needs it but it isn't cached.
    private func ensureMaskIfNeeded() {
        guard canvas.backgroundRemoved, subjectMask == nil, let source = sourceImage,
              !isComputingMask else { return }
        isComputingMask = true
        Task { [weak self] in
            let mask = await SubjectMask.compute(for: source)
            guard let self else { return }
            self.isComputingMask = false
            self.subjectMask = mask
            if mask == nil { self.canvas.backgroundRemoved = false }
            self.scheduleRender()
        }
    }

    // MARK: - Crop

    /// True while the canvas is showing the crop overlay.
    var isCropping = false
    /// The oriented, uncropped source rendered for the crop overlay.
    var cropPreviewImage: NSImage?

    /// Enter crop mode: render the oriented full source (no filters, no crop)
    /// at display-friendly resolution for the overlay to work against.
    func enterCropMode() {
        guard let src = sourceImage else { return }
        let e = src.extent
        let q = ((canvas.orientationQuarters % 4) + 4) % 4
        let w = (q % 2 == 0) ? e.width : e.height
        let h = (q % 2 == 0) ? e.height : e.width
        let scale = min(1, 2048 / max(w, h))
        let request = RenderRequest(
            base: SendableCIImage(src),
            canvasPixelSize: Size2D(width: w, height: h),
            background: .transparent,
            imageFit: .stretch,
            renderScale: scale,
            layers: [RenderLayer(kind: .image, isVisible: true, opacity: 1,
                                 blendMode: .normal, filter: nil, textImage: nil,
                                 position: Point2D(x: 0.5, y: 0.5), rotation: 0)],
            orientationQuarters: canvas.orientationQuarters,
            flippedH: canvas.flippedH,
            subjectMask: nil,
            cropRect: nil)
        Task { [weak self] in
            guard let cg = await RenderEngine.shared.render(request)?.cgImage,
                  let self else { return }
            self.cropPreviewImage = NSImage(cgImage: cg,
                                            size: NSSize(width: cg.width, height: cg.height))
            self.isCropping = true
        }
    }

    /// Commit a crop (normalized, CI coordinates — origin bottom-left) or nil
    /// to clear it. A near-full rect counts as "no crop".
    func applyCrop(_ rect: CGRect?) {
        checkpoint("Crop")
        if let r = rect,
           !(r.minX < 0.005 && r.minY < 0.005 && r.width > 0.995 && r.height > 0.995) {
            canvas.cropRect = CGRect(x: max(0, r.minX), y: max(0, r.minY),
                                     width: min(1 - max(0, r.minX), r.width),
                                     height: min(1 - max(0, r.minY), r.height))
        } else {
            canvas.cropRect = nil
        }
        exitCropMode()
        scheduleRender()
    }

    func exitCropMode() {
        isCropping = false
        cropPreviewImage = nil
    }

    // MARK: - Auto Enhance

    /// Analyze the source and add corrective adjustment layers (exposure,
    /// contrast/saturation) — all fully editable afterwards.
    func autoEnhance() {
        guard let src = sourceImage else { return }
        let instances = ImageStats.autoEnhanceInstances(for: src)
        guard !instances.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Already balanced"
            alert.informativeText = "This image's exposure and color already look good."
            alert.runModal()
            return
        }
        applyFilterStack(name: "Auto Enhance", instances: instances)
    }

    // MARK: - Result to clipboard

    /// Flatten at canvas resolution and put a PNG + TIFF on the pasteboard.
    func copyResultToPasteboard() {
        let request = makeRenderRequest(renderScale: 1)
        Task {
            guard let cg = await RenderEngine.shared.render(request)?.cgImage else {
                NSSound.beep(); return
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            let pb = NSPasteboard.general
            pb.clearContents()
            if let png = rep.representation(using: .png, properties: [:]) {
                pb.setData(png, forType: .png)
            }
            if let tiff = rep.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        }
    }

    // MARK: - Saved Looks support

    /// The current filter layers, bottom-to-top — what "Save Look" captures.
    var currentFilterStack: [FilterInstance] {
        layers.compactMap { $0.kind == .filter ? $0.filter : nil }
    }

    /// Insert an arbitrary filter stack as editable layers (saved Looks).
    func applyFilterStack(name: String, instances: [FilterInstance]) {
        checkpoint("Apply \(name)")
        var idx = insertionIndex()
        var lastID: UUID?
        for instance in instances {
            // Fresh identity so applying the same Look twice can't collide.
            let fresh = FilterInstance(kind: instance.kind,
                                       isEnabled: instance.isEnabled,
                                       parameters: instance.parameters)
            let layer = Layer(name: fresh.kind.displayName, kind: .filter, filter: fresh)
            layers.insert(layer, at: idx)
            lastID = layer.id
            idx += 1
        }
        if let lastID { selectedLayerID = lastID }
        editingFilterLayerID = nil
        scheduleRender()
    }

    func duplicateLayer(_ id: UUID) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("Duplicate Layer")
        let src = layers[idx]
        let copy = Layer(name: src.name,
                        kind: src.kind,
                        isVisible: src.isVisible,
                        opacity: src.opacity,
                        blendMode: src.blendMode,
                        filter: src.filter,
                        text: src.text,
                        // Nudge duplicated text so it's visibly a copy.
                        position: src.kind == .text
                            ? Point2D(x: min(src.position.x + 0.03, 1), y: min(src.position.y + 0.03, 1))
                            : src.position,
                        rotation: src.rotation)
        layers.insert(copy, at: idx + 1)
        selectedLayerID = copy.id
        scheduleRender()
    }

    func removeLayer(_ id: UUID) {
        checkpoint("Delete Layer")
        layers.removeAll { $0.id == id }
        if selectedLayerID == id { selectedLayerID = layers.last?.id }
        if editingFilterLayerID == id { editingFilterLayerID = nil }
        scheduleRender()
    }

    func moveLayers(from source: IndexSet, to dest: Int) {
        checkpoint("Move Layer")
        layers.move(fromOffsets: source, toOffset: dest)
        scheduleRender()
    }

    // MARK: - Undo / Redo (snapshot stacks)

    @ObservationIgnored private var undoStack: [DocumentSnapshot] = []
    @ObservationIgnored private var redoStack: [DocumentSnapshot] = []
    private let undoLimit = 100
    /// Observable mirror so menu items enable/disable correctly.
    private(set) var undoCount = 0
    private(set) var redoCount = 0

    var canUndo: Bool { undoCount > 0 }
    var canRedo: Bool { redoCount > 0 }

    /// Capture the current state before a mutation. Call at the START of any
    /// undoable action. Continuous edits (slider drags) should call
    /// `beginContinuousEdit` once instead of checkpointing every tick.
    func checkpoint(_ name: String = "") {
        undoStack.append(currentSnapshot())
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        coalesceToken = nil
        isDirty = true
        syncUndoCounts()
    }

    /// Coalesced checkpoint for typing: only the FIRST call with a given token
    /// creates an undo step; subsequent calls with the same token are absorbed
    /// until another (regular) checkpoint intervenes.
    @ObservationIgnored private var coalesceToken: String?
    func coalescedCheckpoint(token: String, name: String = "") {
        guard token != coalesceToken else {
            isDirty = true
            return
        }
        checkpoint(name)
        coalesceToken = token
    }

    @ObservationIgnored private var continuousActive = false
    var isContinuousEditing: Bool { continuousActive }
    /// For slider/drag edits: checkpoint once at gesture start, ignore until end.
    func beginContinuousEdit(_ name: String = "") {
        guard !continuousActive else { return }
        continuousActive = true
        checkpoint(name)
    }
    func endContinuousEdit() { continuousActive = false }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        endContinuousEdit()
        coalesceToken = nil
        redoStack.append(currentSnapshot())
        restore(snap)
        postRestoreCleanup()
        isDirty = true
        syncUndoCounts()
        scheduleRender()
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        endContinuousEdit()
        coalesceToken = nil
        undoStack.append(currentSnapshot())
        restore(snap)
        postRestoreCleanup()
        isDirty = true
        syncUndoCounts()
        scheduleRender()
    }

    /// Drop references to layers that no longer exist after a restore.
    private func postRestoreCleanup() {
        if let sel = selectedLayerID, !layers.contains(where: { $0.id == sel }) {
            selectedLayerID = layers.last?.id
        }
        if let ed = editingFilterLayerID, !layers.contains(where: { $0.id == ed }) {
            editingFilterLayerID = nil
        }
    }

    private func syncUndoCounts() {
        undoCount = undoStack.count
        redoCount = redoStack.count
    }

    private func currentSnapshot() -> DocumentSnapshot {
        DocumentSnapshot(
            canvas: .init(width: canvas.width, height: canvas.height,
                          background: canvas.background, imageFit: canvas.imageFit,
                          dpi: canvas.dpi,
                          orientationQuarters: canvas.orientationQuarters,
                          flippedH: canvas.flippedH,
                          backgroundRemoved: canvas.backgroundRemoved,
                          cropX: canvas.cropRect.map { Double($0.minX) },
                          cropY: canvas.cropRect.map { Double($0.minY) },
                          cropW: canvas.cropRect.map { Double($0.width) },
                          cropH: canvas.cropRect.map { Double($0.height) }),
            layers: layers.map { l in
                DocumentSnapshot.LayerState(
                    id: l.id, name: l.name, kind: l.kind.code,
                    isVisible: l.isVisible, opacity: l.opacity,
                    blendMode: l.blendMode == .normal ? nil : l.blendMode.rawValue,
                    filter: l.filter, text: l.text,
                    position: l.position, rotation: l.rotation)
            },
            selectedLayerID: selectedLayerID)
    }

    private func restore(_ snap: DocumentSnapshot) {
        canvas.width = snap.canvas.width
        canvas.height = snap.canvas.height
        canvas.background = snap.canvas.background
        canvas.imageFit = snap.canvas.imageFit
        canvas.dpi = snap.canvas.dpi
        canvas.orientationQuarters = snap.canvas.orientationQuarters ?? 0
        canvas.flippedH = snap.canvas.flippedH ?? false
        canvas.backgroundRemoved = snap.canvas.backgroundRemoved ?? false
        if let x = snap.canvas.cropX, let y = snap.canvas.cropY,
           let w = snap.canvas.cropW, let h = snap.canvas.cropH {
            canvas.cropRect = CGRect(x: x, y: y, width: w, height: h)
        } else {
            canvas.cropRect = nil
        }
        ensureMaskIfNeeded()
        layers = snap.layers.map { s in
            Layer(id: s.id, name: s.name, kind: LayerKind(s.kind),
                  isVisible: s.isVisible, opacity: s.opacity,
                  blendMode: s.blendMode.flatMap(LayerBlendMode.init(rawValue:)) ?? .normal,
                  filter: s.filter, text: s.text,
                  position: s.position, rotation: s.rotation)
        }
        selectedLayerID = snap.selectedLayerID
    }

    // MARK: - Project save / load (.ftrd)

    /// Public snapshot for saving to a .ftrd file.
    func snapshotForSave() -> DocumentSnapshot { currentSnapshot() }

    /// Replace the whole document with a loaded project file.
    func load(from file: FilteredProjectFile, url: URL) {
        // A stale mask from the previous document must never apply here.
        subjectMask = nil
        // Restore the source image first (if embedded).
        if let png = file.sourceImagePNG, let ci = ProjectIO.ciImage(from: png) {
            sourceImage = ci
            if let w = file.sourcePixelWidth, let h = file.sourcePixelHeight, w > 0, h > 0 {
                sourcePixelSize = Size2D(width: Double(w), height: Double(h))
            } else {
                sourcePixelSize = Size2D(ci.extent.size)
            }
        } else {
            sourceImage = nil
            sourcePixelSize = nil
        }
        // Restore editable state.
        restore(file.snapshot)
        postRestoreCleanup()
        projectURL = url
        isDirty = false
        // Fresh undo history for the loaded doc.
        clearUndoHistory()
        scheduleRender()
    }

    private func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        coalesceToken = nil
        syncUndoCounts()
    }

    // MARK: - Preview rendering (debounced, single in-flight)

    /// Call after ANY change that affects the pixels. The Sendable snapshot is
    /// built AFTER the debounce (still on the main actor — the Task inherits
    /// @MainActor isolation), so rapid slider ticks cost almost nothing: no
    /// text rasterization, no snapshot work for cancelled ticks.
    func scheduleRender() {
        renderTask?.cancel()
        isRendering = true
        renderTask = Task { [weak self] in
            // Debounce: coalesce slider-drag ticks.
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled, let self else { return }
            // Preview renders at display resolution, not canvas resolution.
            let request = self.makeRenderRequest(renderScale: self.previewScale)
            let result = await RenderEngine.shared.render(request)
            guard !Task.isCancelled else { return }
            self.isRendering = false
            if let cg = result?.cgImage {
                self.previewImage = NSImage(cgImage: cg,
                                            size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }

    /// Build a Sendable snapshot of the current state. Synchronous, @MainActor.
    /// Text layers are rasterized here via a per-layer cache (only re-rendered
    /// when the text content or scale actually changed).
    func makeRenderRequest(renderScale: Double) -> RenderRequest {
        var renderLayers: [RenderLayer] = []
        for layer in layers {
            switch layer.kind {
            case .image:
                renderLayers.append(RenderLayer(
                    kind: .image,
                    isVisible: layer.isVisible,
                    opacity: layer.opacity,
                    blendMode: layer.blendMode,
                    filter: nil,
                    textImage: nil,
                    position: layer.position,
                    rotation: layer.rotation))
            case .text:
                let ci = layer.cachedTextImage(scale: renderScale)
                renderLayers.append(RenderLayer(
                    kind: .text,
                    isVisible: layer.isVisible,
                    opacity: layer.opacity,
                    blendMode: layer.blendMode,
                    filter: nil,
                    textImage: ci.map(SendableCIImage.init),
                    position: layer.position,
                    rotation: layer.rotation))
            case .filter:
                renderLayers.append(RenderLayer(
                    kind: .filter,
                    // Before/after compare bypasses every filter layer.
                    isVisible: layer.isVisible && !isComparingOriginal,
                    opacity: layer.opacity,
                    blendMode: layer.blendMode,
                    filter: layer.filter,
                    textImage: nil,
                    position: layer.position,
                    rotation: layer.rotation))
            }
        }

        return RenderRequest(
            base: sourceImage.map(SendableCIImage.init),
            canvasPixelSize: canvas.pixelSize,
            background: canvas.background,
            imageFit: canvas.imageFit,
            renderScale: renderScale,
            layers: renderLayers,
            orientationQuarters: canvas.orientationQuarters,
            flippedH: canvas.flippedH,
            subjectMask: canvas.backgroundRemoved ? subjectMask : nil,
            cropRect: canvas.cropRect)
    }
}
