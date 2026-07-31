import SwiftUI

struct InspectorPanel: View {
    @Environment(FilteredDocument.self) private var document

    private func iconName(_ layer: Layer) -> String {
        switch layer.kind {
        case .text: return "textformat"
        case .image: return "photo"
        case .filter: return "camera.filters"
        }
    }
    private func kindLabel(_ layer: Layer) -> String {
        switch layer.kind {
        case .text: return "Text Layer"
        case .image: return "Image Layer"
        case .filter: return "Filter Layer"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let layer = document.selectedLayer {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No opaque fill — let the panel's vibrancy material show through.
        .animation(Motion.ui, value: document.selectedLayerID)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Looks: curated one-click filter stacks — the fast path.
            VStack(alignment: .leading, spacing: 6) {
                Text("Looks").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(LookPreset.all) { look in
                            Button {
                                document.applyLook(look)
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: look.icon)
                                        .font(.system(size: 15, weight: .medium))
                                        .frame(height: 18)
                                    Text(look.name)
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .frame(width: 66, height: 48)
                            }
                            .buttonStyle(.bordered)
                            .help("Apply the \(look.name) look as editable filter layers")
                        }
                    }
                }
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
                ForEach(filter.kind.params) { spec in
                    ParamControl(spec: spec, filter: filterBinding)
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
        }
    }

    private var scalarSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(spec.label).font(.caption)
                Spacer()
                Text(String(format: "%.1f", currentDouble)).font(.caption).monospacedDigit()
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
