import SwiftUI

struct InspectorPanel: View {
    @Environment(FilteredDocument.self) private var document

    private func iconName(_ layer: Layer) -> String {
        switch layer.kind {
        case .text: return "textformat"
        case .image: return "photo"
        case .filter: return "camera.filters"
        case .group: return "folder"
        }
    }
    private func kindLabel(_ layer: Layer) -> String {
        switch layer.kind {
        case .text: return "Text Layer"
        case .image: return "Image Layer"
        case .filter: return "Filter Layer"
        case .group: return "Group"
        }
    }

    var body: some View {
        @Bindable var doc = document
        VStack(spacing: 0) {
            // The two ways of working, made explicit: Presets (one-tap looks)
            // vs Studio (full manual layer editing).
            Picker("", selection: $doc.editorMode) {
                Text("Presets").tag(FilteredDocument.EditorMode.presets)
                Text("Studio").tag(FilteredDocument.EditorMode.studio)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }

            if document.editorMode == .presets {
                PresetsBrowser()
            } else {
                studioContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No opaque fill — let the panel's vibrancy material show through.
        .animation(Motion.ui, value: document.selectedLayerID)
        .animation(Motion.ui, value: document.editorMode)
    }

    @ViewBuilder
    private var studioContent: some View {
        VStack(spacing: 0) {
            if document.selectedLayerIDs.count > 1 {
                MultiSelectionInspector()
            } else if let layer = document.selectedLayer {
                // Header names the selected layer.
                HStack(spacing: 8) {
                    Image(systemName: iconName(layer))
                        .foregroundStyle(Color.accentColor)
                    Text(layer.name)
                        .font(.system(.headline, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(kindLabel(layer))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                // Scroll-edge header: a hairline seam, not a stacked material.
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        switch layer.kind {
                        case .filter:
                            if document.isEditingFilterDetail {
                                // Opened via double-click: edit this filter's params.
                                FilterLayerControls(layer: layer)
                            } else {
                                // Selected but not opened: hint + keep the picker up
                                // so the user can keep stacking more filters.
                                HStack(spacing: 6) {
                                    Image(systemName: "hand.tap")
                                        .foregroundStyle(.secondary)
                                    Text("Double-click this filter layer to edit its parameters")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                                Divider()
                                FilterPickerGrid()
                            }
                        case .text:
                            TextInspectorView(layer: layer)
                            Divider()
                            FilterPickerGrid()
                        case .image:
                            ImageToolsView()
                            Divider()
                            FilterPickerGrid()
                        case .group:
                            GroupInspector(layer: layer)
                            Divider()
                            FilterPickerGrid()
                        }
                    }
                    .padding(Spacing.l)
                }
                .transition(.opacity)
                .id("\(layer.id)-\(document.isEditingFilterDetail)")   // cross-fade on open/close
            } else {
                ContentUnavailableView("No Layer Selected", systemImage: "square.dashed",
                                       description: Text("Import an image or add a text layer"))
            }
        }
    }
}

/// Presets mode: the one-tap gallery. Picking a Look REPLACES the previous
/// pick (like the filter strip in classic photo apps); everything it adds is
/// still real, editable layers — switch to Studio to fine-tune.
private struct PresetsBrowser: View {
    @Environment(FilteredDocument.self) private var document
    @State private var settings = AppSettings.shared

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Pick a look — tap another to swap it. Fine-tune anytime in Studio.")
                    .font(.caption).foregroundStyle(.secondary)

                Button {
                    document.autoEnhance()
                } label: {
                    Label("Auto Enhance", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .disabled(document.baseImage == nil)

                LazyVGrid(columns: columns, spacing: 8) {
                    presetChip(name: "None", icon: "circle.slash",
                               active: document.activeLookName == nil) {
                        document.clearActiveLook()
                    }
                    ForEach(LookPreset.all) { look in
                        presetChip(name: look.name, icon: look.icon,
                                   active: document.activeLookName == look.name) {
                            document.applyLookExclusive(name: look.name,
                                                        instances: look.instances())
                        }
                    }
                }

                if !settings.savedLooks.isEmpty {
                    Text("My Looks").font(.headline).padding(.top, 4)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(settings.savedLooks) { look in
                            presetChip(name: look.name, icon: "star",
                                       active: document.activeLookName == look.name) {
                                document.applyLookExclusive(name: look.name,
                                                            instances: look.filters)
                            }
                            .contextMenu {
                                Button("Delete Look", role: .destructive) {
                                    settings.savedLooks.removeAll { $0.id == look.id }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Spacing.l)
        }
    }

    private func presetChip(name: String, icon: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
        }
        .buttonStyle(.bordered)
        .tint(active ? Color.accentColor : nil)
        .disabled(document.baseImage == nil && name != "None")
    }
}

/// Studio inspector for a multi-selection: group / delete in bulk.
private struct MultiSelectionInspector: View {
    @Environment(FilteredDocument.self) private var document

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(Color.accentColor)
                Text("\(document.selectedLayerIDs.count) Layers Selected")
                    .font(.system(.headline, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    document.groupSelectedLayers()
                } label: {
                    Label("Group Layers", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!document.canGroupSelection)
                .help("Fold the selected layers into a group (⌘G)")

                Button(role: .destructive) {
                    document.deleteSelectedLayers()
                } label: {
                    Label("Delete Layers", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }

                Text("⌘-click layer cards to extend the selection.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.l)
            Spacer()
        }
    }
}

/// Studio inspector for a group layer.
private struct GroupInspector: View {
    @Environment(FilteredDocument.self) private var document
    @Bindable var layer: Layer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Group").font(.headline)
            Text("A group applies its \(layer.children.count) layers together. Use the group's opacity to fade the combined effect, or its blend mode to remix it over the image.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                document.ungroup(layer.id)
            } label: {
                Label("Ungroup", systemImage: "folder.badge.minus")
                    .frame(maxWidth: .infinity)
            }
            .help("Dissolve the group, keeping its layers (⇧⌘G)")
        }
    }
}

/// Inline, always-visible grid of filters grouped by family. Tapping a tile
/// adds a new FILTER LAYER above the current selection.
struct FilterPickerGrid: View {
    @Environment(FilteredDocument.self) private var document
    @State private var settings = AppSettings.shared
    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 8)]

    private func filters(in family: FilterFamily) -> [FilterKind] {
        // Respect the user's enabled/disabled choices from Settings.
        settings.enabledFilters.filter { $0.family == family }.filter { matches($0) }
    }
    private func matches(_ k: FilterKind) -> Bool {
        guard !search.isEmpty else { return true }
        return k.displayName.localizedCaseInsensitiveContains(search)
    }

    private let buttonColumns = [GridItem(.adaptive(minimum: 110), spacing: 6)]

    @State private var showSaveLook = false
    @State private var newLookName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Looks: curated one-click filter stacks — the fast path.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Looks").font(.headline)
                    Spacer()
                    // Capture the current filter stack as a reusable Look.
                    Button {
                        newLookName = ""
                        showSaveLook = true
                    } label: {
                        Label("Save", systemImage: "plus.square.dashed")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(document.currentFilterStack.isEmpty)
                    .help("Save the current filter stack as a Look")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(LookPreset.all) { look in
                            lookChip(name: look.name, icon: look.icon) {
                                document.applyLook(look)
                            }
                        }
                        if !settings.savedLooks.isEmpty {
                            Divider().frame(height: 34)
                            ForEach(settings.savedLooks) { look in
                                lookChip(name: look.name, icon: "star") {
                                    document.applyFilterStack(name: look.name,
                                                              instances: look.filters)
                                }
                                .contextMenu {
                                    Button("Delete Look", role: .destructive) {
                                        settings.savedLooks.removeAll { $0.id == look.id }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .alert("Save Look", isPresented: $showSaveLook) {
                TextField("Name", text: $newLookName)
                Button("Save") {
                    let name = newLookName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    settings.savedLooks.append(
                        SavedLook(name: name, filters: document.currentFilterStack))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves the current filter layers as a reusable Look.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Add Filter Layer").font(.headline)
                Text("Each filter is its own layer, affecting everything below it")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            filterFamilies
        }
    }

    private func lookChip(name: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: 66, height: 48)
        }
        .buttonStyle(.bordered)
        .help("Apply \(name) as editable filter layers")
    }

    @ViewBuilder
    private var filterFamilies: some View {
        ForEach(FilterFamily.allCases) { family in
                let items = filters(in: family)
                if !items.isEmpty {
                    Text(family.displayName)
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    LazyVGrid(columns: buttonColumns, spacing: 6) {
                        ForEach(items) { kind in
                            FilterTile(kind: kind) {
                                document.addFilter(kind)
                            }
                        }
                    }
                }
            }
    }
}

/// Image tools for the base image layer: rotate, flip, subject cutout.
struct ImageToolsView: View {
    @Environment(FilteredDocument.self) private var document

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Image").font(.headline)

            if document.baseImage != nil {
                HistogramView()
            }

            HStack(spacing: 6) {
                Button { document.rotateCounterclockwise() } label: {
                    Image(systemName: "rotate.left")
                }
                .help("Rotate Left")
                Button { document.rotateClockwise() } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate Right")
                Button { document.flipHorizontal() } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip Horizontal")
                Button { document.flipVertical() } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .help("Flip Vertical")
            }
            .disabled(document.baseImage == nil)

            HStack(spacing: 6) {
                Button {
                    document.enterCropMode()
                } label: {
                    Label(document.canvas.cropRect == nil ? "Crop…" : "Edit Crop…",
                          systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .disabled(document.baseImage == nil)
                if document.canvas.cropRect != nil {
                    Button {
                        document.applyCrop(nil)
                    } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Reset Crop")
                }
            }

            Button {
                document.autoEnhance()
            } label: {
                Label("Auto Enhance", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .disabled(document.baseImage == nil)
            .help("Analyze the image and add corrective adjustment layers")

            // Subject cutout (Vision background removal).
            if document.canvas.backgroundRemoved {
                Button {
                    document.restoreBackground()
                } label: {
                    Label("Restore Background", systemImage: "person.and.background.dotted")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    document.removeBackground()
                } label: {
                    if document.isComputingMask {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Finding subject…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Cut Out Subject", systemImage: "person.crop.square.badge.camera")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(document.baseImage == nil || document.isComputingMask)
                .help("Remove the background around the detected subject")
            }
        }
    }
}

/// Parameter controls for a selected FILTER layer.
struct FilterLayerControls: View {
    @Environment(FilteredDocument.self) private var document
    @Bindable var layer: Layer

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let filter = layer.filter {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(filter.kind.displayName).font(.system(.subheadline, weight: .semibold))
                        Text(filter.kind.family.displayName).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { layer.filter?.isEnabled ?? true },
                                             set: { v in
                        document.checkpoint(v ? "Enable Filter" : "Disable Filter")
                        layer.filter?.isEnabled = v; document.scheduleRender()
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }

                Divider()

                if filter.kind.params.isEmpty {
                    Text("This filter has no adjustable parameters").font(.caption).foregroundStyle(.secondary)
                }
                if filter.kind == .levels {
                    // Levels gets its dedicated draggable-histogram control.
                    LevelsControl(layerID: layer.id, filter: filterBinding)
                } else {
                    ForEach(filter.kind.params) { spec in
                        ParamControl(spec: spec, filter: filterBinding)
                    }
                }

                Divider()

                HStack {
                    Text("Layer Opacity").font(.caption)
                    Slider(value: Binding(get: { layer.opacity },
                                          set: { layer.opacity = $0; document.scheduleRender() }),
                           in: 0...1) { editing in
                        editing ? document.beginContinuousEdit("Opacity") : document.endContinuousEdit()
                    }
                    Text("\(Int(layer.opacity * 100))%").font(.caption).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }

                Button(role: .destructive) {
                    document.removeLayer(layer.id)
                } label: {
                    Label("Delete Filter Layer", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
        }
    }

    /// Binding to the layer's single filter instance for the param controls.
    private var filterBinding: Binding<FilterInstance> {
        Binding {
            layer.filter ?? FilterInstance(kind: .mosaic)
        } set: { newValue in
            layer.filter = newValue
        }
    }
}

/// One control (slider / angle / color) bound to a filter parameter.
private struct ParamControl: View {
    @Environment(FilteredDocument.self) private var document
    let spec: FilterParamSpec
    @Binding var filter: FilterInstance

    var body: some View {
        switch spec.kind {
        case .scalar, .pixelScalar:
            scalarSlider
        case .angle:
            angleSlider
        case .color:
            colorControl
        case .center:
            EmptyView()   // center defaults to image center; drag-to-place could be added
        case .bool:
            boolToggle
        case .choice(let options):
            choicePicker(options)
        }
    }

    private func choicePicker(_ options: [String]) -> some View {
        HStack {
            Text(spec.label).font(.caption)
            Spacer()
            Picker("", selection: Binding(
                get: { min(max(Int(currentDouble), 0), options.count - 1) },
                set: { idx in
                    document.checkpoint(spec.label)
                    filter.parameters.set(spec.key, .scalar(Double(idx)))
                    document.scheduleRender()
                })) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i]).tag(i)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var scalarSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(spec.label).font(.caption)
                Spacer()
                Text(String(format: readoutFormat, currentDouble)).font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: doubleBinding, in: spec.min...spec.max) { editing in
                editing ? document.beginContinuousEdit(spec.label) : document.endContinuousEdit()
            }
            .controlSize(.small)
        }
    }

    private var angleSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(spec.label).font(.caption)
                Spacer()
                Text("\(Int(currentDouble * 180 / .pi))°").font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: doubleBinding, in: spec.min...spec.max) { editing in
                editing ? document.beginContinuousEdit(spec.label) : document.endContinuousEdit()
            }
            .controlSize(.small)
        }
    }

    private var colorControl: some View {
        HStack {
            Text(spec.label).font(.caption)
            Spacer()
            ColorPicker("", selection: colorBinding, supportsOpacity: true)
                .labelsHidden()
        }
    }

    private var boolToggle: some View {
        Toggle(spec.label, isOn: boolBinding).font(.caption).controlSize(.small)
    }

    // MARK: bindings
    private var currentDouble: Double {
        filter.parameters[spec.key]?.doubleValue ?? spec.def
    }
    /// Precision matched to the parameter's range: fine ranges (noise level)
    /// need 3 decimals, big ranges (Kelvin) read best as integers.
    private var readoutFormat: String {
        if spec.max - spec.min <= 0.5 { return "%.3f" }
        if spec.max >= 100 { return "%.0f" }
        return "%.1f"
    }
    private var doubleBinding: Binding<Double> {
        Binding {
            filter.parameters[spec.key]?.doubleValue ?? spec.def
        } set: { v in
            filter.parameters.set(spec.key, spec.kind == .angle ? .angle(v) : .scalar(v))
            document.scheduleRender()
        }
    }
    private var colorBinding: Binding<Color> {
        Binding {
            if case .color(let c)? = filter.parameters[spec.key] {
                return Color(c.nsColor)
            }
            return .black
        } set: { c in
            // Color-picker drags stream values; coalesce into one undo step.
            document.coalescedCheckpoint(token: "param-\(filter.id)-\(spec.key)", name: spec.label)
            filter.parameters.set(spec.key, .color(RGBAColor(NSColor(c))))
            document.scheduleRender()
        }
    }
    private var boolBinding: Binding<Bool> {
        Binding {
            if case .bool(let b)? = filter.parameters[spec.key] { return b }
            return spec.def != 0
        } set: { b in
            filter.parameters.set(spec.key, .bool(b))
            document.scheduleRender()
        }
    }
}
