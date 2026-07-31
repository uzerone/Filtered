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
        isDirty = false
        canvas = CanvasSettings()
        clearUndoHistory()
        scheduleRender()
    }

    func setSourceImage(_ image: CIImage, pixelSize: Size2D) {
        sourceImage = image
        sourcePixelSize = pixelSize
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

    func duplicateLayer(_ id: UUID) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("Duplicate Layer")
        let src = layers[idx]
        let copy = Layer(name: src.name,
                        kind: src.kind,
                        isVisible: src.isVisible,
                        opacity: src.opacity,
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
                          dpi: canvas.dpi),
            layers: layers.map { l in
                DocumentSnapshot.LayerState(
                    id: l.id, name: l.name, kind: l.kind.code,
                    isVisible: l.isVisible, opacity: l.opacity,
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
        layers = snap.layers.map { s in
            Layer(id: s.id, name: s.name, kind: LayerKind(s.kind),
                  isVisible: s.isVisible, opacity: s.opacity,
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
            layers: renderLayers)
    }
}
