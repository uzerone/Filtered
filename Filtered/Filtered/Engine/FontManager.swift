import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers
import CoreText

/// Provides the full list of installed macOS font families and supports
/// importing custom font files (.ttf/.otf/.ttc) at runtime.
@MainActor
@Observable
final class FontManager {
    static let shared = FontManager()

    /// All available font family names, alphabetized. Includes any imported fonts.
    private(set) var families: [String] = []

    /// PostScript names of fonts the user imported this session (for labeling).
    private(set) var importedPostScriptNames: Set<String> = []

    init() {
        reloadFamilies()
    }

    func reloadFamilies() {
        families = NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Members (styles) of a family, as (displayName, postScriptName) pairs.
    func members(of family: String) -> [(style: String, postScriptName: String)] {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return members.compactMap { arr in
            guard arr.count >= 2,
                  let ps = arr[0] as? String,
                  let style = arr[1] as? String else { return nil }
            return (style, ps)
        }
    }

    /// The default PostScript name to use for a family (first regular-ish member).
    func defaultPostScriptName(for family: String) -> String {
        let members = members(of: family)
        if let regular = members.first(where: { $0.style.localizedCaseInsensitiveContains("Regular") }) {
            return regular.postScriptName
        }
        return members.first?.postScriptName
            ?? NSFont(name: family, size: 12)?.fontName
            ?? family
    }

    /// The family that owns a PostScript font name (for showing current selection).
    func family(forPostScriptName ps: String) -> String? {
        NSFont(name: ps, size: 12)?.familyName
    }

    // MARK: - Custom font import
    //
    // Imported fonts are COPIED into the app container and registered from the
    // private copies. This is durable: no security-scoped bookmarks, no scope
    // that must stay open while CoreText lazily maps glyph data, and fonts
    // survive the original file being moved or deleted.

    /// Imported font file names (for display in Settings).
    private(set) var importedFontFiles: [(name: String, url: URL)] = []

    /// The app-container directory that holds imported font copies.
    private var fontsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Filtered/Fonts", isDirectory: true)
    }

    /// Register every font previously copied into the container. Also migrates
    /// any fonts saved by the old bookmark system into the container.
    func restoreImportedFonts() {
        let fm = FileManager.default
        try? fm.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)

        // One-time migration from the old security-scoped-bookmark storage.
        let oldBookmarks = AppSettings.shared.importedFontBookmarks
        if !oldBookmarks.isEmpty {
            for data in oldBookmarks {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data,
                                         options: [.withSecurityScope],
                                         relativeTo: nil,
                                         bookmarkDataIsStale: &stale) else { continue }
                let ok = url.startAccessingSecurityScopedResource()
                let dest = fontsDirectory.appendingPathComponent(url.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: url, to: dest)
                }
                if ok { url.stopAccessingSecurityScopedResource() }
            }
            AppSettings.shared.importedFontBookmarks = []
        }

        // Register everything in the container.
        let contents = (try? fm.contentsOfDirectory(at: fontsDirectory,
                                                    includingPropertiesForKeys: nil)) ?? []
        for url in contents where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            if let ps = register(url: url) {
                importedPostScriptNames.insert(ps)
                importedFontFiles.append((url.lastPathComponent, url))
            }
        }
        reloadFamilies()
    }

    /// Present an open panel, copy the chosen font files into the container,
    /// and register the copies. Returns the PostScript name of the first newly
    /// available font, if any.
    @discardableResult
    func importFonts() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "ttf") ?? .font,
            UTType(filenameExtension: "otf") ?? .font,
            UTType(filenameExtension: "ttc") ?? .font,
            .font,
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }

        let fm = FileManager.default
        try? fm.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)

        var firstPS: String?
        for url in panel.urls {
            let dest = fontsDirectory.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            guard (try? fm.copyItem(at: url, to: dest)) != nil else { continue }
            if let ps = register(url: dest) {
                importedPostScriptNames.insert(ps)
                importedFontFiles.removeAll { $0.name == dest.lastPathComponent }
                importedFontFiles.append((dest.lastPathComponent, dest))
                if firstPS == nil { firstPS = ps }
            }
        }
        reloadFamilies()
        return firstPS
    }

    /// Register a font file with the process so NSFont(name:) can find it.
    private func register(url: URL) -> String? {
        var errorRef: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef)
        if !ok {
            // Already-registered is fine; other errors we just skip.
            errorRef?.release()
        }
        // Read the PostScript name from the font file.
        guard let dataProvider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(dataProvider),
              let psName = cgFont.postScriptName as String? else { return nil }
        return psName
    }
}
