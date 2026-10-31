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
    /// Primary selection (drives the inspector).
    var selectedLayerID: UUID?
    /// Full selection set (⌘-click extends). Always contains the primary.
    var selectedLayerIDs: Set<UUID> = []
    /// Groups currently expanded in the layers panel (UI state, not undoable).
    var expandedGroups: Set<UUID> = []

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

    /// The two ways of working, mirrored by the inspector's top switch:
    /// **Presets** — one-tap Looks that swap wholesale (the fast path);
    /// **Studio** — the full manual layer/filter editor.
    enum EditorMode: String {
        case presets, studio
    }
    var editorMode: EditorMode = .presets

    /// Name of the preset currently applied via Presets mode (chip highlight).
    var activeLookName: String?
    /// The layers that preset created — swapped out when another is chosen.
    @ObservationIgnored private var activeLookLayerIDs: [UUID] = []

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
        setPrimarySelection(id)
        editingFilterLayerID = nil
    }

    /// ⌘-click: toggle a layer in/out of the multi-selection.
    func toggleLayerSelection(_ id: UUID) {
        editingFilterLayerID = nil
        if selectedLayerIDs.contains(id) {
            selectedLayerIDs.remove(id)
            if selectedLayerID == id { selectedLayerID = selectedLayerIDs.first }
        } else {
            selectedLayerIDs.insert(id)
            selectedLayerID = id
        }
    }

    /// Set a single-layer selection, keeping the set in sync.
    func setPrimarySelection(_ id: UUID?) {
        selectedLayerID = id
        selectedLayerIDs = id.map { [$0] } ?? []
    }

    /// Double-click a filter layer: open its detail parameters.
    func openFilterDetail(_ id: UUID) {
        setPrimarySelection(id)
        editingFilterLayerID = id
    }

    func closeFilterDetail() {
        editingFilterLayerID = nil
    }

    /// The imported source image at native resolution (kept for full-res export).
    /// For animated sources this is the CURRENT frame — the whole pipeline
    /// (filters, text, crop, export) is frame-agnostic and just uses it.
    var sourceImage: CIImage?
    var sourcePixelSize: Size2D?

    // MARK: - Animated sources (GIF / APNG)

    /// All decoded frames (nil / single frame = static image).
    var animationFrames: [AnimationFrame]?
    /// The original encoded file bytes (embedded in .ftrd so projects reopen
    /// with full animation).
    @ObservationIgnored var animationData: Data?
    var currentFrameIndex = 0
    var isPlaying = false
    @ObservationIgnored private var playbackTask: Task<Void, Never>?

    var isAnimated: Bool { (animationFrames?.count ?? 0) > 1 }
    var frameCount: Int { animationFrames?.count ?? 0 }

    /// Install an animated source. Reuses the static-image reset path, then
    /// attaches the frames.
    func setAnimatedSource(frames: [AnimationFrame], data: Data?, pixelSize: Size2D) {
        guard let first = frames.first else { return }
        setSourceImage(first.image, pixelSize: pixelSize)
        animationFrames = frames
        animationData = data
        currentFrameIndex = 0
    }

    /// Jump to a frame. Navigation, not an edit: no checkpoint, no dirty flag.
    func showFrame(_ index: Int) {
        guard let frames = animationFrames, frames.indices.contains(index) else { return }
        currentFrameIndex = index
        sourceImage = frames[index].image
        scheduleRender()
    }

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    private func startPlayback() {
        guard let frames = animationFrames, frames.count > 1 else { return }
        isPlaying = true
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { break }
                let next = (self.currentFrameIndex + 1) % frames.count
                self.showFrame(next)
                let delay = max(frames[next].delay, 0.02)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

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

    /// All layers with group children flattened in, depth-first in stack order.
    var flattenedLayers: [Layer] {
        layers.flatMap { $0.kind == .group ? [$0] + $0.children : [$0] }
    }

    /// Text layers that should show canvas drag handles: visible, and not
    /// inside a hidden group.
    var visibleTextLayers: [Layer] {
        layers.flatMap { layer -> [Layer] in
            if layer.kind == .group {
                return layer.isVisible
                    ? layer.children.filter { $0.kind == .text && $0.isVisible } : []
            }
            return (layer.kind == .text && layer.isVisible) ? [layer] : []
        }
    }

    var selectedLayer: Layer? {
        guard let id = selectedLayerID else { return nil }
        return flattenedLayers.first { $0.id == id }
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

    /// Ask before destroying unsaved work (New Canvas / Open Project). Returns
    /// true when it's safe to proceed — either the doc is clean, the user saved,
    /// or the user chose to discard. Mirrors the quit-time guard in AppDelegate.
    func confirmDiscardChanges() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(projectName)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return ProjectIO.save(document: self)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func newCanvas() {
        guard confirmDiscardChanges() else { return }
        stopPlayback()
        layers = []
        sourceImage = nil
        sourcePixelSize = nil
        animationFrames = nil
        animationData = nil
        currentFrameIndex = 0
        previewImage = nil
        setPrimarySelection(nil)
        editingFilterLayerID = nil
        projectURL = nil
        subjectMask = nil
        isDirty = false
        canvas = CanvasSettings()
        clearUndoHistory()
        scheduleRender()
    }

    func setSourceImage(_ image: CIImage, pixelSize: Size2D) {
        stopPlayback()
        sourceImage = image
        sourcePixelSize = pixelSize
        // A new source replaces any previous animation until (re)attached.
        animationFrames = nil
        animationData = nil
        currentFrameIndex = 0
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
            setPrimarySelection(layer.id)
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
        setPrimarySelection(layer.id)
        scheduleRender()
    }

    /// Add a filter as its own adjustment layer, inserted directly ABOVE the
    /// currently selected layer (so it affects everything at/below the selection),
    /// or on top of the stack if nothing is selected.
    func addFilter(_ kind: FilterKind) {
        checkpoint("Add \(kind.displayName)")
        let layer = Layer.filterLayer(kind)
        insertNewLayer(layer)
        setPrimarySelection(layer.id)
        scheduleRender()
    }

    /// Apply a Look: insert its whole filter stack as editable filter layers.
    func applyLook(_ look: LookPreset) {
        applyFilterStack(name: look.name, instances: look.instances())
    }

    /// Insert a new layer just above the selection — into the same group when
    /// the selection is a group child — or on top of the stack otherwise.
    private func insertNewLayer(_ layer: Layer) {
        if let sel = selectedLayerID {
            if let idx = layers.firstIndex(where: { $0.id == sel }) {
                layers.insert(layer, at: idx + 1)
                return
            }
            for group in layers where group.kind == .group {
                if let cidx = group.children.firstIndex(where: { $0.id == sel }) {
                    group.children.insert(layer, at: cidx + 1)
                    return
                }
            }
        }
        layers.append(layer)
    }

    // MARK: - Layer groups

    /// True when the current selection can be grouped: at least one top-level
    /// filter/text layer selected (the base image and existing groups stay put).
    var canGroupSelection: Bool {
        layers.contains { selectedLayerIDs.contains($0.id)
            && $0.kind != .image && $0.kind != .group }
    }

    /// Fold the selected top-level layers into a new group at the position of
    /// the bottom-most member, preserving their stacking order.
    func groupSelectedLayers() {
        let members = layers.filter { selectedLayerIDs.contains($0.id)
            && $0.kind != .image && $0.kind != .group }
        guard !members.isEmpty else { return }
        checkpoint("Group Layers")
        let bottomIdx = layers.firstIndex { $0.id == members[0].id } ?? 0
        layers.removeAll { l in members.contains { $0.id == l.id } }
        let group = Layer.groupLayer(children: members)
        layers.insert(group, at: min(bottomIdx, layers.count))
        expandedGroups.insert(group.id)
        setPrimarySelection(group.id)
        editingFilterLayerID = nil
        scheduleRender()
    }

    /// Dissolve a group: splice its children back at the group's position.
    func ungroup(_ id: UUID) {
        guard let idx = layers.firstIndex(where: { $0.id == id }),
              layers[idx].kind == .group else { return }
        checkpoint("Ungroup")
        let children = layers[idx].children
        layers.remove(at: idx)
        layers.insert(contentsOf: children, at: idx)
        expandedGroups.remove(id)
        setPrimarySelection(children.last?.id)
        scheduleRender()
    }

    /// Add an empty group above the selection.
    func addEmptyGroup() {
        checkpoint("Add Group")
        let group = Layer.groupLayer()
        insertNewLayer(group)
        expandedGroups.insert(group.id)
        setPrimarySelection(group.id)
        scheduleRender()
    }

    /// Move a top-level layer into a group (appended on top of its children).
    func moveLayer(_ id: UUID, intoGroup groupID: UUID) {
        guard let group = layers.first(where: { $0.id == groupID }), group.kind == .group,
              let idx = layers.firstIndex(where: { $0.id == id }),
              layers[idx].kind != .image, layers[idx].kind != .group else { return }
        checkpoint("Move into Group")
        let layer = layers.remove(at: idx)
        group.children.append(layer)
        expandedGroups.insert(groupID)
        setPrimarySelection(layer.id)
        scheduleRender()
    }

    /// Move a group child back to the top level, just above its group.
    func moveLayerOutOfGroup(_ id: UUID) {
        for (gidx, group) in layers.enumerated() where group.kind == .group {
            if let cidx = group.children.firstIndex(where: { $0.id == id }) {
                checkpoint("Remove from Group")
                let layer = group.children.remove(at: cidx)
                layers.insert(layer, at: gidx + 1)
                setPrimarySelection(layer.id)
                scheduleRender()
                return
            }
        }
    }

    /// Reorder within a group (chevron buttons in the layers panel).
    func moveChild(in group: Layer, from: Int, to: Int) {
        guard group.children.indices.contains(from),
              group.children.indices.contains(to) else { return }
        checkpoint("Move Layer")
        let layer = group.children.remove(at: from)
        group.children.insert(layer, at: to)
        scheduleRender()
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

    /// The current filter layers, bottom-to-top (groups flattened in) — what
    /// "Save Look" captures.
    var currentFilterStack: [FilterInstance] {
        flattenedLayers.compactMap { $0.kind == .filter ? $0.filter : nil }
    }

    /// Insert an arbitrary filter stack as editable layers (Looks).
    func applyFilterStack(name: String, instances: [FilterInstance]) {
        checkpoint("Apply \(name)")
        for instance in instances {
            // Fresh identity so applying the same Look twice can't collide.
            let fresh = FilterInstance(kind: instance.kind,
                                       isEnabled: instance.isEnabled,
                                       parameters: instance.parameters)
            let layer = Layer(name: fresh.kind.displayName, kind: .filter, filter: fresh)
            insertNewLayer(layer)
            // Advance the selection so the next instance stacks above this one.
            setPrimarySelection(layer.id)
        }
        editingFilterLayerID = nil
        scheduleRender()
    }

    /// Presets mode: applying a Look REPLACES the previous preset's layers
    /// (one-tap filter semantics) instead of stacking like Studio mode does.
    func applyLookExclusive(name: String, instances: [FilterInstance]) {
        checkpoint("Apply \(name)")
        removeActiveLookLayers()
        var newIDs: [UUID] = []
        for instance in instances {
            let fresh = FilterInstance(kind: instance.kind,
                                       isEnabled: instance.isEnabled,
                                       parameters: instance.parameters)
            let layer = Layer(name: fresh.kind.displayName, kind: .filter, filter: fresh)
            layers.append(layer)
            newIDs.append(layer.id)
        }
        activeLookLayerIDs = newIDs
        activeLookName = name
        setPrimarySelection(newIDs.last)
        editingFilterLayerID = nil
        scheduleRender()
    }

    /// Presets mode "None": remove the active preset's layers.
    func clearActiveLook() {
        guard activeLookName != nil || !activeLookLayerIDs.isEmpty else { return }
        checkpoint("Remove Look")
        removeActiveLookLayers()
        cleanUpSelectionAfterRemoval()
        scheduleRender()
    }

    private func removeActiveLookLayers() {
        let stale = Set(activeLookLayerIDs)
        if !stale.isEmpty {
            layers.removeAll { stale.contains($0.id) }
            for group in layers where group.kind == .group {
                group.children.removeAll { stale.contains($0.id) }
            }
        }
        activeLookLayerIDs = []
        activeLookName = nil
    }

    /// Deep copy with fresh identities (layer ids and FilterInstance ids) —
    /// shared ids would cross-wire selection and undo coalescing.
    private func deepCopy(_ src: Layer) -> Layer {
        Layer(name: src.name,
              kind: src.kind,
              isVisible: src.isVisible,
              opacity: src.opacity,
              blendMode: src.blendMode,
              filter: src.filter.map {
                  FilterInstance(kind: $0.kind, isEnabled: $0.isEnabled, parameters: $0.parameters)
              },
              text: src.text,
              // Nudge duplicated text so it's visibly a copy.
              position: src.kind == .text
                  ? Point2D(x: min(src.position.x + 0.03, 1), y: min(src.position.y + 0.03, 1))
                  : src.position,
              rotation: src.rotation,
              children: src.children.map { deepCopy($0) })
    }

    func duplicateLayer(_ id: UUID) {
        checkpoint("Duplicate Layer")
        if let idx = layers.firstIndex(where: { $0.id == id }) {
            let copy = deepCopy(layers[idx])
            layers.insert(copy, at: idx + 1)
            setPrimarySelection(copy.id)
            scheduleRender()
            return
        }
        for group in layers where group.kind == .group {
            if let cidx = group.children.firstIndex(where: { $0.id == id }) {
                let copy = deepCopy(group.children[cidx])
                group.children.insert(copy, at: cidx + 1)
                setPrimarySelection(copy.id)
                scheduleRender()
                return
            }
        }
    }

    func removeLayer(_ id: UUID) {
        checkpoint("Delete Layer")
        removeLayerNoCheckpoint(id)
        cleanUpSelectionAfterRemoval()
        scheduleRender()
    }

    /// Delete every layer in the multi-selection as one undo step.
    func deleteSelectedLayers() {
        guard !selectedLayerIDs.isEmpty else { return }
        checkpoint("Delete Layers")
        for id in selectedLayerIDs { removeLayerNoCheckpoint(id) }
        cleanUpSelectionAfterRemoval()
        scheduleRender()
    }

    private func removeLayerNoCheckpoint(_ id: UUID) {
        if layers.contains(where: { $0.id == id }) {
            layers.removeAll { $0.id == id }
            return
        }
        for group in layers where group.kind == .group {
            group.children.removeAll { $0.id == id }
        }
    }

    private func cleanUpSelectionAfterRemoval() {
        let existing = Set(flattenedLayers.map(\.id))
        selectedLayerIDs.formIntersection(existing)
        if let sel = selectedLayerID, !existing.contains(sel) {
            setPrimarySelection(selectedLayerIDs.first ?? layers.last?.id)
        }
        if let ed = editingFilterLayerID, !existing.contains(ed) {
            editingFilterLayerID = nil
        }
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
        let existing = Set(flattenedLayers.map(\.id))
        selectedLayerIDs.formIntersection(existing)
        if let sel = selectedLayerID, !existing.contains(sel) {
            setPrimarySelection(layers.last?.id)
        }
        if let ed = editingFilterLayerID, !existing.contains(ed) {
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
            layers: layers.map { layerState($0) },
            selectedLayerID: selectedLayerID)
    }

    private func layerState(_ l: Layer) -> DocumentSnapshot.LayerState {
        DocumentSnapshot.LayerState(
            id: l.id, name: l.name, kind: l.kind.code,
            isVisible: l.isVisible, opacity: l.opacity,
            blendMode: l.blendMode == .normal ? nil : l.blendMode.rawValue,
            filter: l.filter, text: l.text,
            position: l.position, rotation: l.rotation,
            children: l.kind == .group ? l.children.map { layerState($0) } : nil)
    }

    private func layer(from s: DocumentSnapshot.LayerState) -> Layer {
        Layer(id: s.id, name: s.name, kind: LayerKind(s.kind),
              isVisible: s.isVisible, opacity: s.opacity,
              blendMode: s.blendMode.flatMap(LayerBlendMode.init(rawValue:)) ?? .normal,
              filter: s.filter, text: s.text,
              position: s.position, rotation: s.rotation,
              children: s.children?.map { layer(from: $0) } ?? [])
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
        layers = snap.layers.map { layer(from: $0) }
        setPrimarySelection(snap.selectedLayerID)
    }

    // MARK: - Project save / load (.ftrd)

    /// Public snapshot for saving to a .ftrd file.
    func snapshotForSave() -> DocumentSnapshot { currentSnapshot() }

    /// Replace the whole document with a loaded project file.
    func load(from file: FilteredProjectFile, url: URL) {
        stopPlayback()
        // A stale mask from the previous document must never apply here.
        subjectMask = nil
        animationFrames = nil
        animationData = nil
        currentFrameIndex = 0
        // Restore the animated source if embedded, else the still PNG.
        if let animated = file.sourceAnimatedData,
           let decoded = ImageImporter.loadAnimatedFrames(data: animated) {
            sourceImage = decoded.frames.first?.image
            sourcePixelSize = decoded.size
            animationFrames = decoded.frames
            animationData = animated
        } else if let png = file.sourceImagePNG, let ci = ProjectIO.ciImage(from: png) {
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
    ///
    /// `upTo` truncates the stack just below that layer id (used by the Levels
    /// control to histogram its input). `baseOverride` swaps the base image
    /// without touching the document (used by animated export).
    func makeRenderRequest(renderScale: Double,
                           upTo stopID: UUID? = nil,
                           baseOverride: CIImage? = nil) -> RenderRequest {
        var stopped = false

        func build(_ source: [Layer]) -> [RenderLayer] {
            var out: [RenderLayer] = []
            for layer in source {
                if stopped { break }
                if layer.id == stopID { stopped = true; break }
                switch layer.kind {
                case .image:
                    out.append(RenderLayer(
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
                    out.append(RenderLayer(
                        kind: .text,
                        isVisible: layer.isVisible,
                        opacity: layer.opacity,
                        blendMode: layer.blendMode,
                        filter: nil,
                        textImage: ci.map(SendableCIImage.init),
                        position: layer.position,
                        rotation: layer.rotation))
                case .filter:
                    out.append(RenderLayer(
                        kind: .filter,
                        // Before/after compare bypasses every filter layer.
                        isVisible: layer.isVisible && !isComparingOriginal,
                        opacity: layer.opacity,
                        blendMode: layer.blendMode,
                        filter: layer.filter,
                        textImage: nil,
                        position: layer.position,
                        rotation: layer.rotation))
                case .group:
                    out.append(RenderLayer(
                        kind: .group,
                        isVisible: layer.isVisible,
                        opacity: layer.opacity,
                        blendMode: layer.blendMode,
                        filter: nil,
                        textImage: nil,
                        position: layer.position,
                        rotation: layer.rotation,
                        children: build(layer.children)))
                }
            }
            return out
        }

        let renderLayers = build(layers)
        return RenderRequest(
            base: (baseOverride ?? sourceImage).map(SendableCIImage.init),
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

/// One decoded frame of an animated source (GIF/APNG). Not actor-isolated so
/// the decoder can build these outside the main actor.
struct AnimationFrame {
    let image: CIImage
    let delay: Double      // seconds
}
