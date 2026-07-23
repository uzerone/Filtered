import SwiftUI
import AppKit

/// Editing controls for a text layer, with full native + imported font support.
struct TextInspectorView: View {
    @Environment(FilteredDocument.self) private var document
    @State private var fonts = FontManager.shared
    @Bindable var layer: Layer

    private var currentFamily: String {
        fonts.family(forPostScriptName: layer.text?.fontName ?? "") ?? "PingFang SC"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text").font(.headline)

            TextEditor(text: textBinding)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))

            // Font family + style + import.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if let ps = fonts.importFonts() {
                            setFontName(ps)
                        }
                    } label: {
                        Label("Import Font", systemImage: "plus")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
                FontFamilyPicker(selectedFamily: currentFamily) { family in
                    setFontName(fonts.defaultPostScriptName(for: family))
                }
                // Style (weight/italic) within the family.
                let members = fonts.members(of: currentFamily)
                if members.count > 1 {
                    Picker("Style", selection: fontStyleBinding) {
                        ForEach(members, id: \.postScriptName) { m in
                            Text(m.style).tag(m.postScriptName)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            SliderRow(label: "Size", value: sizeBinding, range: 8...400, format: "%.0f",
                      onEdit: continuousEdit)

            HStack {
                Text("Color").font(.caption)
                ColorPicker("", selection: colorBinding, supportsOpacity: true).labelsHidden()
                Spacer()
                Picker("", selection: alignmentBinding) {
                    Image(systemName: "text.alignleft").tag(TextAlignmentValue.left)
                    Image(systemName: "text.aligncenter").tag(TextAlignmentValue.center)
                    Image(systemName: "text.alignright").tag(TextAlignmentValue.right)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }

            SliderRow(label: "Tracking", value: trackingBinding, range: -5...30, format: "%.0f",
                      onEdit: continuousEdit)
            SliderRow(label: "Leading", value: lineSpacingBinding, range: 0...40, format: "%.0f",
                      onEdit: continuousEdit)
        }
    }

    // MARK: font mutation
    private func setFontName(_ ps: String) {
        document.checkpoint("Change Font")
        var t = layer.text ?? TextContent()
        t.fontName = ps
        layer.text = t
        document.scheduleRender()
    }

    private var fontStyleBinding: Binding<String> {
        Binding { layer.text?.fontName ?? "" }
        set: { setFontName($0) }
    }

    private func continuousEdit(_ editing: Bool) {
        if editing { document.beginContinuousEdit("Edit Text") }
        else { document.endContinuousEdit() }
    }

    // MARK: bindings into layer.text (TextContent)
    private func bindText<T>(_ keyPath: WritableKeyPath<TextContent, T>, default def: T) -> Binding<T> {
        Binding {
            layer.text?[keyPath: keyPath] ?? def
        } set: { v in
            var t = layer.text ?? TextContent()
            t[keyPath: keyPath] = v
            layer.text = t
            layer.name = String((layer.text?.string ?? "Text").prefix(12))
            document.scheduleRender()
        }
    }

    private var textBinding: Binding<String> {
        Binding {
            layer.text?.string ?? ""
        } set: { v in
            if !document.isContinuousEditing { document.checkpoint("Edit Text") }
            var t = layer.text ?? TextContent()
            t.string = v
            layer.text = t
            layer.name = String(v.prefix(12))
            document.scheduleRender()
        }
    }
    private var sizeBinding: Binding<Double> { bindText(\.fontSize, default: 64) }
    private var trackingBinding: Binding<Double> { bindText(\.tracking, default: 0) }
    private var lineSpacingBinding: Binding<Double> { bindText(\.lineSpacing, default: 0) }
    private var alignmentBinding: Binding<TextAlignmentValue> {
        Binding { layer.text?.alignment ?? .left }
        set: { v in
            document.checkpoint("Alignment")
            var t = layer.text ?? TextContent(); t.alignment = v; layer.text = t
            document.scheduleRender()
        }
    }
    private var colorBinding: Binding<Color> {
        Binding {
            Color((layer.text?.color ?? .white).nsColor)
        } set: { c in
            var t = layer.text ?? TextContent()
            t.color = RGBAColor(NSColor(c))
            layer.text = t
            document.scheduleRender()
        }
    }
}

/// A native, searchable font-family picker that previews each family in its own face.
struct FontFamilyPicker: View {
    let selectedFamily: String
    let onSelect: (String) -> Void
    @State private var fonts = FontManager.shared
    @State private var search = ""

    var body: some View {
        Menu {
            TextField("Search fonts…", text: $search)
            Divider()
            ForEach(filtered, id: \.self) { family in
                Button {
                    onSelect(family)
                } label: {
                    Text(family)
                    if family == selectedFamily { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack {
                Text(selectedFamily).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
    }

    private var filtered: [String] {
        guard !search.isEmpty else { return fonts.families }
        return fonts.families.filter { $0.localizedCaseInsensitiveContains(search) }
    }
}

/// A labeled slider with value readout that reports editing start/end so the
/// document can coalesce a drag into a single undo step.
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.1f"
    var onEdit: ((Bool) -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 56, alignment: .leading)
            Slider(value: $value, in: range) { editing in
                onEdit?(editing)
            }
            .controlSize(.small)
            Text(String(format: format, value)).font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}
