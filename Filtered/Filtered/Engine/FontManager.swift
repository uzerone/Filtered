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

    /// Imported font file names (for display in Settings).
    private(set) var importedFontFiles: [(name: String, url: URL)] = []

    /// Restore fonts imported in previous sessions from saved bookmarks.
    func restoreImportedFonts() {
        var stillValid: [Data] = []
        for data in AppSettings.shared.importedFontBookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: [.withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { continue }
            let ok = url.startAccessingSecurityScopedResource()
            if register(url: url) != nil {
                importedFontFiles.append((url.lastPathComponent, url))
                stillValid.append(data)
            }
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        AppSettings.shared.importedFontBookmarks = stillValid
        reloadFamilies()
    }

    /// Present an open panel and register the chosen font files. Returns the
    /// PostScript name of the first newly available font, if any.
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

        var firstPS: String?
        var newBookmarks = AppSettings.shared.importedFontBookmarks
        for url in panel.urls {
            if let ps = register(url: url) {
                importedPostScriptNames.insert(ps)
                importedFontFiles.append((url.lastPathComponent, url))
                if firstPS == nil { firstPS = ps }
                // Persist a security-scoped bookmark so it survives relaunch.
                if let bm = try? url.bookmarkData(options: [.withSecurityScope],
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
                    newBookmarks.append(bm)
                }
            }
        }
        AppSettings.shared.importedFontBookmarks = newBookmarks
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
