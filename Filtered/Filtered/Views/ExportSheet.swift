import SwiftUI

struct ExportSheet: View {
    @Environment(FilteredDocument.self) private var document
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .png
    @State private var quality: Double = 0.9
    @State private var useCustomSize = false
    @State private var scaleIndex = 0   // 0=1x … 3=4x
    @State private var customWidth: Int = 1080
    @State private var customHeight: Int = 1080
    @State private var lockAspect = true
    @State private var batchScales = false
    @State private var isExporting = false

    private let scaleOptions: [Double] = [1, 2, 3, 4]

    private var sizeMode: ExportSizeMode {
        useCustomSize ? .custom(width: customWidth, height: customHeight)
                      : .scale(scaleOptions[scaleIndex])
    }

    private var outSize: (Int, Int) {
        ExportOptions(format: format, quality: quality, sizeMode: sizeMode)
            .outputSize(canvasWidth: document.canvas.width, canvasHeight: document.canvas.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Image").font(.title2).bold()

            // Format.
            VStack(alignment: .leading, spacing: 6) {
                Text("Format").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $format) {
                    ForEach(ExportFormat.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(format.supportsTransparency ? "Supports transparency" : "No transparency (transparent areas filled black)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            if format.isLossy {
                HStack {
                    Text("Quality").font(.caption).frame(width: 40, alignment: .leading)
                    Slider(value: $quality, in: 0.3...1)
                    Text("\(Int(quality * 100))%").font(.caption).monospacedDigit().frame(width: 44)
                }
            }

            Divider()

            // Size.
            VStack(alignment: .leading, spacing: 8) {
                Picker("Size", selection: $useCustomSize) {
                    Text("Scale").tag(false)
                    Text("Custom").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if useCustomSize {
                    HStack(spacing: 6) {
                        LabeledInt(label: "W", value: $customWidth) { newW in
                            if lockAspect {
                                customHeight = Int(Double(newW) / document.canvas.aspectRatio)
                            }
                        }
                        Text("×").foregroundStyle(.secondary)
                        LabeledInt(label: "H", value: $customHeight) { newH in
                            if lockAspect {
                                customWidth = Int(Double(newH) * document.canvas.aspectRatio)
                            }
                        }
                        Button {
                            lockAspect.toggle()
                        } label: {
                            Image(systemName: lockAspect ? "lock" : "lock.open")
                        }
                        .buttonStyle(.borderless)
                        .help(lockAspect ? "Lock ratio" : "Free ratio")
                    }
                } else {
                    Picker("", selection: $scaleIndex) {
                        ForEach(scaleOptions.indices, id: \.self) { i in
                            Text("\(Int(scaleOptions[i]))×").tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(batchScales)

                    Toggle("Export @1× @2× @3× together", isOn: $batchScales)
                        .font(.caption)
                }

                let (w, h) = outSize
                Label("Output: \(w) × \(h) px", systemImage: "aspectratio")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    export()
                } label: {
                    if isExporting { ProgressView().controlSize(.small) }
                    else { Text("Export…") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            customWidth = document.canvas.width
            customHeight = document.canvas.height
        }
    }

    private func export() {
        isExporting = true
        let options = ExportOptions(format: format, quality: quality, sizeMode: sizeMode,
                                    batchScales: batchScales && !useCustomSize)
        Task {
            await ImageExporter.exportPanel(document: document, options: options)
            await MainActor.run {
                isExporting = false
                dismiss()
            }
        }
    }
}

private struct LabeledInt: View {
    let label: String
    @Binding var value: Int
    var onCommit: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .onChange(of: value) { _, newValue in onCommit(newValue) }
        }
    }
}
