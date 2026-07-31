import Foundation
import CoreImage
import AppKit
import UniformTypeIdentifiers

/// The Filtered project document type (.ftrd). Self-contained: the editable
/// state (canvas, layers, filters, text) PLUS the embedded source image, so the
/// file is portable and always reopens correctly.
extension UTType {
    static var filteredProject: UTType {
        UTType(exportedAs: "com.filtered.project", conformingTo: .data)
    }
}

/// The on-disk representation of a saved project. Codable → JSON.
struct FilteredProjectFile: Codable {
    /// Format version for forward compatibility.
    var version: Int = 1
    var app: String = "Filtered"
    var author: String = ""

    /// Editable document state (canvas + layers + filters + text).
    var snapshot: DocumentSnapshot

    /// The source image encoded as PNG (base64 via Data's Codable), if present.
    var sourceImagePNG: Data?
    var sourcePixelWidth: Int?
    var sourcePixelHeight: Int?

    static let fileExtension = "ftrd"
}

enum ProjectIO {
    /// Shared context for PNG-encoding the embedded source image — CIContext
    /// creation is expensive, so never make one per save.
    private static let encodeContext = CIContext(options: [.cacheIntermediates: false])

    /// Serialize the current document to .ftrd data.
    @MainActor
    static func encode(_ document: FilteredDocument) -> Data? {
        var file = FilteredProjectFile(
            author: AppSettings.shared.authorCredit,
            snapshot: document.snapshotForSave())

        // Embed the source image as PNG.
        if let ci = document.sourceImage,
           let png = pngData(from: ci, pixelSize: document.sourcePixelSize) {
            file.sourceImagePNG = png
            file.sourcePixelWidth = Int(document.sourcePixelSize?.width ?? 0)
            file.sourcePixelHeight = Int(document.sourcePixelSize?.height ?? 0)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(file)
    }

    /// Parse .ftrd data into a project file struct.
    static func decode(_ data: Data) -> FilteredProjectFile? {
        try? JSONDecoder().decode(FilteredProjectFile.self, from: data)
    }

    // MARK: Save / Open panels

    /// Save to the current project URL, surfacing failures with a recovery
    /// path — silent data loss on ⌘S is never acceptable.
    @MainActor
    @discardableResult
    static func save(document: FilteredDocument) -> Bool {
        guard let data = encode(document) else {
            presentError("Save failed", "The project could not be encoded.")
            return false
        }
        if let url = document.projectURL {
            do {
                try data.write(to: url, options: .atomic)
                document.isDirty = false
                return true
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save “\(url.lastPathComponent)”"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Save As…")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    return saveAs(document: document)
                }
                return false
            }
        }
        return saveAs(document: document)
    }

    @MainActor
    @discardableResult
    static func saveAs(document: FilteredDocument) -> Bool {
        guard let data = encode(document) else {
            presentError("Save failed", "The project could not be encoded.")
            return false
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.filteredProject]
        panel.nameFieldStringValue = "Untitled.\(FilteredProjectFile.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url, options: .atomic)
            document.projectURL = url
            document.isDirty = false
            return true
        } catch {
            presentError("Couldn't save “\(url.lastPathComponent)”", error.localizedDescription)
            return false
        }
    }

    @MainActor
    static func open(into document: FilteredDocument) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.filteredProject]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(at: url, into: document)
    }

    @MainActor
    static func openFile(at url: URL, into document: FilteredDocument) {
        guard let data = try? Data(contentsOf: url) else {
            presentError("Couldn't open “\(url.lastPathComponent)”", "The file could not be read.")
            return
        }
        guard let file = decode(data) else {
            presentError("Couldn't open “\(url.lastPathComponent)”",
                         "The file is not a valid Filtered project.")
            return
        }
        document.load(from: file, url: url)
    }

    @MainActor
    private static func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Helpers

    static func pngData(from ci: CIImage, pixelSize: Size2D?) -> Data? {
        let rect = pixelSize.map { CGRect(x: 0, y: 0, width: $0.width, height: $0.height) }
            ?? ci.extent
        guard rect.width >= 1, rect.height >= 1,
              let cg = encodeContext.createCGImage(ci, from: rect) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }

    static func ciImage(from png: Data) -> CIImage? {
        CIImage(data: png)
    }
}
