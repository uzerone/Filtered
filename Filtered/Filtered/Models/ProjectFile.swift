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

    @MainActor
    static func save(document: FilteredDocument) {
        guard let data = encode(document) else { NSSound.beep(); return }
        // If we already have a file URL, overwrite silently; else ask.
        if let url = document.projectURL {
            try? data.write(to: url)
            return
        }
        saveAs(document: document)
    }

    @MainActor
    static func saveAs(document: FilteredDocument) {
        guard let data = encode(document) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.filteredProject]
        panel.nameFieldStringValue = "Untitled.\(FilteredProjectFile.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            document.projectURL = url
        } catch {
            NSSound.beep()
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
        guard let data = try? Data(contentsOf: url),
              let file = decode(data) else { NSSound.beep(); return }
        document.load(from: file, url: url)
    }

    // MARK: Helpers

    static func pngData(from ci: CIImage, pixelSize: Size2D?) -> Data? {
        let context = CIContext()
        let rect = pixelSize.map { CGRect(x: 0, y: 0, width: $0.width, height: $0.height) }
            ?? ci.extent
        guard rect.width >= 1, rect.height >= 1,
              let cg = context.createCGImage(ci, from: rect) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }

    static func ciImage(from png: Data) -> CIImage? {
        CIImage(data: png)
    }
}
