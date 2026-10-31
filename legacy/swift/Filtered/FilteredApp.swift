import SwiftUI
import AppKit

/// App delegate: guards quit while there are unsaved changes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var document: FilteredDocument?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let doc = Self.document, doc.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(doc.projectName)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return ProjectIO.save(document: doc) ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

@main
struct FilteredApp: App {
    @State private var document: FilteredDocument
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let doc = FilteredDocument()
        _document = State(initialValue: doc)
        AppDelegate.document = doc
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
                Menu("Open Recent") {
                    ForEach(AppSettings.shared.recentProjects, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) {
                            ProjectIO.openFile(at: URL(fileURLWithPath: path), into: document)
                        }
                    }
                    if !AppSettings.shared.recentProjects.isEmpty {
                        Divider()
                        Button("Clear Menu") { AppSettings.shared.recentProjects = [] }
                    }
                }
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
                // ⇧⌘ variants so plain ⌘C/⌘V still work inside text fields.
                Button("Copy Image") { document.copyResultToPasteboard() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(document.baseImage == nil && document.layers.isEmpty)
                Button("Paste Image") {
                    if !ImageImporter.importFromPasteboard(into: document) {
                        NSSound.beep()
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Add Text Layer") { document.addTextLayer() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Duplicate Layer") {
                    if let id = document.selectedLayerID { document.duplicateLayer(id) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(document.selectedLayerID == nil)
                Button("Delete Selected Layer") {
                    document.deleteSelectedLayers()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(document.selectedLayerIDs.isEmpty)
                Divider()
                Button("Group Selected Layers") { document.groupSelectedLayers() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(!document.canGroupSelection)
                Button("Ungroup") {
                    if let id = document.selectedLayerID { document.ungroup(id) }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(document.selectedLayer?.kind != .group)
            }
            // Image menu: rotate / flip / subject cutout.
            CommandMenu("Image") {
                Button("Rotate Left") { document.rotateCounterclockwise() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("Rotate Right") { document.rotateClockwise() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Flip Horizontal") { document.flipHorizontal() }
                Button("Flip Vertical") { document.flipVertical() }
                Divider()
                Button("Crop…") { document.enterCropMode() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .disabled(document.baseImage == nil)
                Button("Reset Crop") { document.applyCrop(nil) }
                    .disabled(document.canvas.cropRect == nil)
                Button("Auto Enhance") { document.autoEnhance() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(document.baseImage == nil)
                Divider()
                if document.canvas.backgroundRemoved {
                    Button("Restore Background") { document.restoreBackground() }
                } else {
                    Button("Cut Out Subject") { document.removeBackground() }
                        .disabled(document.baseImage == nil || document.isComputingMask)
                }
            }
            // Zoom — inserted into the system View menu (a CommandMenu("View")
            // would create a duplicate menu next to the built-in one).
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Zoom In") { document.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { document.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Zoom to Fit") { document.zoomToFit() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                // Toggle sibling of the hold-to-compare toolbar eye.
                Button(document.isComparingOriginal ? "Show Edited" : "Compare with Original") {
                    document.isComparingOriginal.toggle()
                }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(document.baseImage == nil)
            }
        }

        // Settings window (⌘,)
        Settings {
            SettingsView()
        }
    }
}
