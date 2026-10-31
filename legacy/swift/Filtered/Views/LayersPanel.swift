import SwiftUI

struct LayersPanel: View {
    @Environment(FilteredDocument.self) private var document
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            CanvasSizeControl()
            Divider()
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Menu {
                    Button("Add Text Layer") { document.addTextLayer() }
                    Button("Import Image…") { document.requestImport = true }
                    Divider()
                    Button("New Group") { document.addEmptyGroup() }
                    Button("Group Selected Layers") { document.groupSelectedLayers() }
                        .disabled(!document.canGroupSelection)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if document.layers.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No layers yet")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Import an image or add text")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: Spacing.s) {
                        // Top layer first (drawn last / on top).
                        ForEach(Array(document.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                            LayerCard(layer: layer, index: index)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.92).combined(with: .opacity),
                                    removal: .scale(scale: 0.92).combined(with: .opacity)))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .animation(reduceMotion ? Motion.fade : Motion.bouncy,
                               value: document.layers.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? Motion.fade : Motion.ui, value: document.layers.isEmpty)
    }
}

/// Shared helpers for layer rows/cards.
@MainActor
private func layerIcon(_ layer: Layer) -> String {
    switch layer.kind {
    case .text: return "textformat"
    case .image: return "photo"
    case .filter: return "camera.filters"
    case .group: return "folder"
    }
}
@MainActor
private func layerKindLabel(_ layer: Layer) -> String {
    switch layer.kind {
    case .text: return "Text Layer"
    case .image: return "Image Layer"
    case .filter: return "Filter Layer"
    case .group: return "Group · \(layer.children.count) layers"
    }
}

/// Each layer shown as its own expanded card — never collapsed into a single row.
private struct LayerCard: View {
    @Environment(FilteredDocument.self) private var document
    @Bindable var layer: Layer
    let index: Int

    private var isSelected: Bool { document.selectedLayerIDs.contains(layer.id) }
    private var canMoveUp: Bool { index < document.layers.count - 1 }
    private var canMoveDown: Bool { index > 0 }
    private var isExpanded: Bool { document.expandedGroups.contains(layer.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + editable name + visibility.
            HStack(spacing: 8) {
                Image(systemName: layerIcon(layer))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)

                TextField("Layer name", text: Binding(
                    get: { layer.name },
                    set: { v in
                        document.coalescedCheckpoint(token: "rename-\(layer.id)", name: "Rename Layer")
                        layer.name = v
                    }))
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.medium))

                Spacer()

                if layer.kind == .group {
                    Button {
                        withAnimation(Motion.quick) {
                            if isExpanded { document.expandedGroups.remove(layer.id) }
                            else { document.expandedGroups.insert(layer.id) }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? "Collapse group" : "Expand group")
                }

                VisibilityButton(layer: layer)
            }

            Text(layerKindLabel(layer))
                .font(.caption2).foregroundStyle(.tertiary)

            // Opacity.
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { layer.opacity },
                                      set: { layer.opacity = $0; document.scheduleRender() }),
                       in: 0...1) { editing in
                    editing ? document.beginContinuousEdit("Opacity") : document.endContinuousEdit()
                }
                .controlSize(.mini)
                Text("\(Int(layer.opacity * 100))%")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            // Blend mode.
            HStack(spacing: 6) {
                Image(systemName: "circle.tophalf.filled.inverse")
                    .font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { layer.blendMode },
                    set: { v in
                        document.checkpoint("Blend Mode")
                        layer.blendMode = v
                        document.scheduleRender()
                    })) {
                    ForEach(LayerBlendMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
            }

            // Group children, indented, top-of-stack first.
            if layer.kind == .group && isExpanded {
                Divider()
                if layer.children.isEmpty {
                    Text("Empty group — right-click a layer to move it here")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(layer.children.enumerated()).reversed(),
                                id: \.element.id) { cidx, child in
                            GroupChildRow(group: layer, child: child, childIndex: cidx)
                        }
                    }
                }
            }

            // Reorder + delete.
            HStack(spacing: 4) {
                Button { move(up: true) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(!canMoveUp)
                Button { move(up: false) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(!canMoveDown)
                Spacer()
                if layer.kind == .group {
                    Button {
                        document.ungroup(layer.id)
                    } label: { Image(systemName: "folder.badge.minus") }
                        .buttonStyle(.borderless)
                        .help("Ungroup (⇧⌘G)")
                }
                Button {
                    document.duplicateLayer(layer.id)
                } label: { Image(systemName: "plus.square.on.square") }
                    .buttonStyle(.borderless)
                    .help("Duplicate Layer (⌘D)")
                Button(role: .destructive) {
                    document.removeLayer(layer.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete Layer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .cardSurface(selected: isSelected)
        .contextMenu {
            if document.selectedLayerIDs.count > 1 && document.canGroupSelection {
                Button("Group Selected Layers") { document.groupSelectedLayers() }
                Divider()
            }
            if layer.kind == .group {
                Button("Ungroup") { document.ungroup(layer.id) }
            } else if layer.kind != .image {
                let groups = document.layers.filter { $0.kind == .group && $0.id != layer.id }
                if !groups.isEmpty {
                    Menu("Move into Group") {
                        ForEach(groups) { g in
                            Button(g.name) { document.moveLayer(layer.id, intoGroup: g.id) }
                        }
                    }
                }
            }
            Button("Duplicate") { document.duplicateLayer(layer.id) }
            Button("Delete", role: .destructive) { document.removeLayer(layer.id) }
        }
        .contentShape(Rectangle())
        // Selection via SIMULTANEOUS gestures so the card's buttons (eye,
        // chevrons, trash) always receive their clicks — plain onTapGesture on
        // the card was swallowing them on macOS. ⌘-click extends the selection;
        // double-click opens filter detail / toggles group expansion.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if layer.kind == .filter {
                withAnimation(Motion.quick) { document.openFilterDetail(layer.id) }
            } else if layer.kind == .group {
                withAnimation(Motion.quick) {
                    if isExpanded { document.expandedGroups.remove(layer.id) }
                    else { document.expandedGroups.insert(layer.id) }
                }
            }
        })
        .simultaneousGesture(TapGesture().onEnded {
            if NSEvent.modifierFlags.contains(.command) {
                document.toggleLayerSelection(layer.id)
            } else {
                withAnimation(Motion.quick) { document.selectLayer(layer.id) }
            }
        })
        .animation(Motion.quick, value: isSelected)
    }

    private func move(up: Bool) {
        // up = toward top of stack (higher index).
        let from = index
        let to = up ? index + 1 : index - 1
        guard to >= 0, to < document.layers.count else { return }
        // Convert to the move API (offsets/destination semantics).
        let dest = up ? to + 1 : to
        document.moveLayers(from: IndexSet(integer: from), to: dest)
    }
}

/// The visibility (eye) toggle, with a solid hit target so clicks land.
private struct VisibilityButton: View {
    @Environment(FilteredDocument.self) private var document
    @Bindable var layer: Layer

    var body: some View {
        Button {
            document.checkpoint("Toggle Visibility")
            layer.isVisible.toggle()
            document.scheduleRender()
        } label: {
            Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(layer.isVisible ? "Hide layer" : "Show layer")
    }
}

/// A compact row for a layer inside a group.
private struct GroupChildRow: View {
    @Environment(FilteredDocument.self) private var document
    @Bindable var group: Layer
    @Bindable var child: Layer
    let childIndex: Int

    private var isSelected: Bool { document.selectedLayerIDs.contains(child.id) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: layerIcon(child))
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(child.name)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button {
                document.moveChild(in: group, from: childIndex, to: childIndex + 1)
            } label: { Image(systemName: "chevron.up").font(.caption2) }
                .buttonStyle(.borderless)
                .disabled(childIndex >= group.children.count - 1)
            Button {
                document.moveChild(in: group, from: childIndex, to: childIndex - 1)
            } label: { Image(systemName: "chevron.down").font(.caption2) }
                .buttonStyle(.borderless)
                .disabled(childIndex <= 0)
            VisibilityButton(layer: child)
                .controlSize(.small)
        }
        .padding(.vertical, 5).padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                 : AnyShapeStyle(.quaternary.opacity(0.25)))
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if child.kind == .filter {
                withAnimation(Motion.quick) { document.openFilterDetail(child.id) }
            }
        })
        .simultaneousGesture(TapGesture().onEnded {
            if NSEvent.modifierFlags.contains(.command) {
                document.toggleLayerSelection(child.id)
            } else {
                withAnimation(Motion.quick) { document.selectLayer(child.id) }
            }
        })
        .contextMenu {
            Button("Remove from Group") { document.moveLayerOutOfGroup(child.id) }
            Button("Duplicate") { document.duplicateLayer(child.id) }
            Button("Delete", role: .destructive) { document.removeLayer(child.id) }
        }
    }
}

struct CanvasSizeControl: View {
    @Environment(FilteredDocument.self) private var document
    /// When true the canvas dimensions are frozen — W/H and presets are
    /// read-only until the user unlocks.
    @State private var sizeLocked = false

    /// Clamped dimension binding: rejects zero/negative/absurd sizes that
    /// would produce an invalid render extent.
    private func dimensionBinding(_ keyPath: ReferenceWritableKeyPath<CanvasSettings, Int>) -> Binding<Int> {
        Binding {
            document.canvas[keyPath: keyPath]
        } set: { v in
            let clamped = min(max(v, 1), 16384)
            guard clamped != document.canvas[keyPath: keyPath] else { return }
            // One undo step per typing session, not per digit.
            document.coalescedCheckpoint(token: "canvas-size", name: "Canvas Size")
            document.canvas[keyPath: keyPath] = clamped
        }
    }

    var body: some View {
        @Bindable var doc = document
        VStack(alignment: .leading, spacing: 8) {
            Text("Canvas").font(.headline)
            // W × H, a lock toggle, and the Presets menu — all on one row.
            HStack(spacing: 4) {
                LabeledStepperField(label: "W", value: dimensionBinding(\.width))
                    .disabled(sizeLocked)
                Text("×").foregroundStyle(.secondary).font(.caption)
                LabeledStepperField(label: "H", value: dimensionBinding(\.height))
                    .disabled(sizeLocked)

                Button {
                    sizeLocked.toggle()
                } label: {
                    Image(systemName: sizeLocked ? "lock.fill" : "lock.open")
                        .foregroundStyle(sizeLocked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(sizeLocked ? "Size locked — click to unlock" : "Lock canvas size")

                Menu {
                    ForEach(CanvasSettings.presetGroups) { group in
                        Section(group.title) {
                            ForEach(group.presets) { preset in
                                Button("\(preset.name)  (\(preset.width)×\(preset.height))") {
                                    document.checkpoint("Canvas Preset")
                                    document.canvas.apply(preset)
                                    document.scheduleRender()
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ruler")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(sizeLocked)
                .help("Size presets")
            }

            Picker("Fit", selection: Binding(
                get: { document.canvas.imageFit },
                set: { v in
                    document.checkpoint("Image Fit")
                    document.canvas.imageFit = v
                    document.scheduleRender()
                })) {
                ForEach(ImageFit.allCases) { fit in
                    Text(fit.displayName).tag(fit)
                }
            }
            .pickerStyle(.segmented)
            .font(.caption)

            HStack(spacing: 6) {
                Text("BG").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: backgroundBinding) {
                    Text("None").tag(0)
                    Text("Black").tag(1)
                    Text("White").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: doc.canvas.width) { _, _ in document.scheduleRender() }
        .onChange(of: doc.canvas.height) { _, _ in document.scheduleRender() }
    }

    private var backgroundBinding: Binding<Int> {
        Binding {
            switch document.canvas.background {
            case .transparent: return 0
            case .solid(let c): return c.r < 0.5 ? 1 : 2
            }
        } set: { newValue in
            document.checkpoint("Background")
            switch newValue {
            case 0: document.canvas.background = .transparent
            case 1: document.canvas.background = .solid(.black)
            default: document.canvas.background = .solid(.white)
            }
            document.scheduleRender()
        }
    }
}

private struct LabeledStepperField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 44, maxWidth: .infinity)   // flex, don't overflow
                .multilineTextAlignment(.trailing)
        }
        .layoutPriority(1)
    }
}
