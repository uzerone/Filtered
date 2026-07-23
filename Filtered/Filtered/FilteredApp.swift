import SwiftUI

@main
struct FilteredApp: App {
    @State private var document = FilteredDocument()

    init() {
        // Re-register fonts imported in previous sessions.
        FontManager.shared.restoreImportedFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(document)
                .frame(minWidth: 980, minHeight: 640)
                .onOpenURL { url in
                    // Double-clicked a .ftrd file in Finder.
                    if url.pathExtension.lowercased() == FilteredProjectFile.fileExtension {
                        ProjectIO.openFile(at: url, into: document)
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentMinSize)   // window can't shrink below content min
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Canvas") { document.newCanvas() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Import Image…") { document.requestImport = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Project…") { ProjectIO.open(into: document) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            // Save / Save As for the .ftrd project.
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { ProjectIO.save(document: document) }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { ProjectIO.saveAs(document: document) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export Image…") { document.requestExport = true }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(document.baseImage == nil)
            }
            // Replace the standard Undo/Redo so ⌘Z / ⇧⌘Z drive our snapshot stack.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { document.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!document.canUndo)
                Button("Redo") { document.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!document.canRedo)
            }
            // Edit menu additions
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Add Text Layer") { document.addTextLayer() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Delete Selected Layer") {
                    if let id = document.selectedLayerID { document.removeLayer(id) }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(document.selectedLayerID == nil)
            }
        }

        // Settings window (⌘,)
        Settings {
            SettingsView()
        }
    }
}
