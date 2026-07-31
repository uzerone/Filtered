import SwiftUI

struct ContentView: View {
    @Environment(FilteredDocument.self) private var document
    @State private var showExport = false

    var body: some View {
        @Bindable var doc = document
        // Three fixed panels in a plain HStack. This is a TOOL layout, not a
        // navigation layout, so it deliberately does NOT use NavigationSplitView —
        // that container's collapse/slide machinery was what clipped the sidebar
        // content. An HStack just places children at their widths; nothing to clip.
        HStack(spacing: 0) {
            // Left tool panel — genuine macOS sidebar vibrancy (material chrome).
            LayersPanel()
                .frame(width: 280)
                .background(VisualEffect(material: .sidebar).ignoresSafeArea())

            panelSeam

            // Canvas sits in a recessed content well, visually "below" the chrome
            // (Apple §12: material weight encodes hierarchy — content recedes).
            CanvasView()
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor).ignoresSafeArea())

            panelSeam

            // Right inspector — lighter material so interactive controls draw focus.
            InspectorPanel()
                .frame(width: 320)
                .background(VisualEffect(material: .contentBackground).ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Window chrome tells the truth: which project, and whether it has
        // unsaved edits.
        .navigationTitle(document.projectName)
        .navigationSubtitle(document.isDirty ? "Edited" : "")
        .toolbar { toolbarContent }
        .onChange(of: doc.requestImport) { _, want in
            if want { doc.requestImport = false; importImage() }
        }
        .onChange(of: doc.requestExport) { _, want in
            if want { doc.requestExport = false; showExport = true }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet()
        }
        .onAppear { if document.layers.isEmpty { document.scheduleRender() } }
    }

    /// A hairline seam between panels — subtler than a hard Divider, reads as
    /// the edge where one material meets another.
    private var panelSeam: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                importImage()
            } label: { Label("Import", systemImage: "photo.on.rectangle") }

            Button {
                document.addTextLayer()
            } label: { Label("Text", systemImage: "textformat") }
        }

        ToolbarItemGroup {
            // Zoom menu: current % as the label, common levels inside.
            Menu {
                Button("Zoom In") { document.zoomIn() }
                Button("Zoom Out") { document.zoomOut() }
                Button("Zoom to Fit") { document.zoomToFit() }
                Divider()
                Button("50%") { document.canvasZoom = 0.5 }
                Button("100%") { document.canvasZoom = 1 }
                Button("200%") { document.canvasZoom = 2 }
                Button("400%") { document.canvasZoom = 4 }
            } label: {
                Text("\(Int(document.canvasZoom * 100))%")
                    .monospacedDigit()
            }
            .help("Zoom")

            // Hold to compare with the unfiltered original (press-down feedback,
            // release restores — Apple §1: respond on press, not release).
            Image(systemName: document.isComparingOriginal ? "eye.fill" : "eye")
                .foregroundStyle(document.isComparingOriginal ? Color.accentColor : .primary)
                .onLongPressGesture(minimumDuration: .infinity) {
                } onPressingChanged: { pressing in
                    document.isComparingOriginal = pressing
                }
                .help("Hold to compare with original")
                .accessibilityLabel("Compare with original")

            Button {
                showExport = true
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .disabled(document.baseImage == nil)

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    private func importImage() {
        if let (image, size) = ImageImporter.openPanel() {
            document.setSourceImage(image, pixelSize: size)
        }
    }
}
