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

    private var renderTask: Task<Void, Never>?

    var selectedLayer: Layer? {
        guard let id = selectedLayerID else { return nil }
        return layers.first { $0.id == id }
    }

    var baseImage: CIImage? { sourceImage }

    // MARK: - Document lifecycle

    func newCanvas() {
        layers = []
        sourceImage = nil
        sourcePixelSize = nil
        previewImage = nil
        selectedLayerID = nil
        canvas = CanvasSettings()
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
        if let sel = selectedLayerID,
           let idx = layers.firstIndex(where: { $0.id == sel }) {
            layers.insert(layer, at: idx + 1)
        } else {
            layers.append(layer)
        }
        selectedLayerID = layer.id
        scheduleRender()
    }

    func removeLayer(_ id: UUID) {
        checkpoint("Delete Layer")
        layers.removeAll { $0.id == id }
        if selectedLayerID == id { selectedLayerID = layers.last?.id }
        scheduleRender()
    }

    func moveLayers(from source: IndexSet, to dest: Int) {
        checkpoint("Move Layer")
        layers.move(fromOffsets: source, toOffset: dest)
        scheduleRender()
    }

    // MARK: - Undo / Redo (snapshot stacks)

    private var undoStack: [DocumentSnapshot] = []
    private var redoStack: [DocumentSnapshot] = []
    private let undoLimit = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Capture the current state before a mutation. Call at the START of any
    /// undoable action. Continuous edits (slider drags) should call
    /// `beginContinuousEdit` once instead of checkpointing every tick.
    func checkpoint(_ name: String = "") {
        undoStack.append(currentSnapshot())
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private var continuousActive = false
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
        redoStack.append(currentSnapshot())
        restore(snap)
        scheduleRender()
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        restore(snap)
        scheduleRender()
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
        projectURL = url
        // Fresh undo history for the loaded doc.
        clearUndoHistory()
        scheduleRender()
    }

    private func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - Preview rendering (debounced, single in-flight)

    /// Call after ANY change that affects the pixels. Reads state synchronously
    /// on the main actor into a Sendable snapshot, then renders off-actor.
    func scheduleRender() {
        renderTask?.cancel()
        let request = makeRenderRequest(renderScale: 1)
        isRendering = true
        renderTask = Task { [weak self] in
            // Small debounce so slider drags don't storm the engine.
            try? await Task.sleep(nanoseconds: 16_000_000)
            if Task.isCancelled { return }
            let result = await RenderEngine.shared.render(request)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.isRendering = false
                if let cg = result?.cgImage {
                    self.previewImage = NSImage(cgImage: cg,
                                                size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }
    }

    /// Build a Sendable snapshot of the current state. Synchronous, @MainActor.
    /// Text layers are pre-rendered here (TextRenderer is @MainActor).
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
                let ci = layer.text.flatMap { TextRenderer.render($0, scale: renderScale) }
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
                    isVisible: layer.isVisible,
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
