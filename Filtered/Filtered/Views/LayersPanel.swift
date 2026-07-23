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

/// Each layer shown as its own expanded card — never collapsed into a single row.
private struct LayerCard: View {
    @Environment(FilteredDocument.self) private var document
    @Bindable var layer: Layer
    let index: Int

    private var isSelected: Bool { document.selectedLayerID == layer.id }
    private var canMoveUp: Bool { index < document.layers.count - 1 }
    private var canMoveDown: Bool { index > 0 }

    private var iconName: String {
        switch layer.kind {
        case .text: return "textformat"
        case .image: return "photo"
        case .filter: return "camera.filters"
        }
    }
    private var kindLabel: String {
        switch layer.kind {
        case .text: return "Text Layer"
        case .image: return "Image Layer"
        case .filter: return "Filter Layer"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + editable name + visibility.
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)

                TextField("Layer name", text: $layer.name)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Button {
                    layer.isVisible.toggle()
                    document.scheduleRender()
                } label: {
                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                        .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                }
                .buttonStyle(.borderless)
            }

            Text(kindLabel)
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

            // Reorder + delete.
            HStack(spacing: 4) {
                Button { move(up: true) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(!canMoveUp)
                Button { move(up: false) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(!canMoveDown)
                Spacer()
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
        .contentShape(Rectangle())
        // Double-click a filter layer opens its detail params;
        // single-click just selects (so you can keep adding filters).
        .onTapGesture(count: 2) {
            if layer.kind == .filter {
                withAnimation(Motion.quick) { document.openFilterDetail(layer.id) }
            } else {
                withAnimation(Motion.quick) { document.selectLayer(layer.id) }
            }
        }
        .onTapGesture(count: 1) {
            withAnimation(Motion.quick) { document.selectLayer(layer.id) }
        }
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

struct CanvasSizeControl: View {
    @Environment(FilteredDocument.self) private var document
    /// When true the canvas dimensions are frozen — W/H and presets are
    /// read-only until the user unlocks.
    @State private var sizeLocked = false

    var body: some View {
        @Bindable var doc = document
        VStack(alignment: .leading, spacing: 8) {
            Text("Canvas").font(.headline)
            // W × H, a lock toggle, and the Presets menu — all on one row.
            HStack(spacing: 4) {
                LabeledStepperField(label: "W", value: $doc.canvas.width)
                    .disabled(sizeLocked)
                Text("×").foregroundStyle(.secondary).font(.caption)
                LabeledStepperField(label: "H", value: $doc.canvas.height)
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

            Picker("Fit", selection: $doc.canvas.imageFit) {
                ForEach(ImageFit.allCases) { fit in
                    Text(fit.displayName).tag(fit)
                }
            }
            .pickerStyle(.segmented)
            .font(.caption)
            .onChange(of: doc.canvas.imageFit) { _, _ in document.scheduleRender() }

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
