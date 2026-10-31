import Foundation
import Observation
import SwiftUI

/// App-wide, persisted settings (fonts, filter visibility, author/export metadata).
/// Backed by UserDefaults so choices survive relaunches.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    // MARK: Author / export metadata
    var authorName: String {
        didSet { defaults.set(authorName, forKey: Keys.authorName) }
    }
    var authorHandle: String {
        didSet { defaults.set(authorHandle, forKey: Keys.authorHandle) }
    }
    /// Embed author + app name into exported image metadata (EXIF/IPTC).
    var embedAuthorMetadata: Bool {
        didSet { defaults.set(embedAuthorMetadata, forKey: Keys.embedMeta) }
    }
    /// Draw a small author watermark in the corner of exports.
    var addWatermark: Bool {
        didSet { defaults.set(addWatermark, forKey: Keys.watermark) }
    }
    var watermarkText: String {
        didSet { defaults.set(watermarkText, forKey: Keys.watermarkText) }
    }

    // MARK: Filter management — which filter kinds appear in the picker.
    /// Stored as the set of DISABLED filter raw values (default: none disabled).
    var disabledFilters: Set<String> {
        didSet { defaults.set(Array(disabledFilters), forKey: Keys.disabledFilters) }
    }

    // MARK: Imported fonts (persisted list of bookmarked font-file URLs).
    /// Security-scoped bookmarks so imported fonts re-register on next launch.
    var importedFontBookmarks: [Data] {
        didSet { defaults.set(importedFontBookmarks, forKey: Keys.fontBookmarks) }
    }

    // MARK: User-saved Looks (named filter stacks), JSON-encoded.
    var savedLooks: [SavedLook] {
        didSet {
            if let data = try? JSONEncoder().encode(savedLooks) {
                defaults.set(data, forKey: Keys.savedLooks)
            }
        }
    }

    // MARK: Recent projects (paths, most recent first, max 10).
    var recentProjects: [String] {
        didSet { defaults.set(recentProjects, forKey: Keys.recentProjects) }
    }

    func noteRecentProject(_ url: URL) {
        var list = recentProjects.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        recentProjects = Array(list.prefix(10))
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let authorName = "authorName"
        static let authorHandle = "authorHandle"
        static let embedMeta = "embedAuthorMetadata"
        static let watermark = "addWatermark"
        static let watermarkText = "watermarkText"
        static let disabledFilters = "disabledFilters"
        static let fontBookmarks = "importedFontBookmarks"
        static let savedLooks = "savedLooks"
        static let recentProjects = "recentProjects"
    }

    private init() {
        authorName = defaults.string(forKey: Keys.authorName) ?? ""
        authorHandle = defaults.string(forKey: Keys.authorHandle) ?? ""
        embedAuthorMetadata = defaults.object(forKey: Keys.embedMeta) as? Bool ?? true
        addWatermark = defaults.bool(forKey: Keys.watermark)
        watermarkText = defaults.string(forKey: Keys.watermarkText) ?? ""
        disabledFilters = Set(defaults.stringArray(forKey: Keys.disabledFilters) ?? [])
        importedFontBookmarks = (defaults.array(forKey: Keys.fontBookmarks) as? [Data]) ?? []
        savedLooks = (defaults.data(forKey: Keys.savedLooks))
            .flatMap { try? JSONDecoder().decode([SavedLook].self, from: $0) } ?? []
        recentProjects = defaults.stringArray(forKey: Keys.recentProjects) ?? []
    }

    // MARK: Filter helpers
    func isEnabled(_ kind: FilterKind) -> Bool { !disabledFilters.contains(kind.rawValue) }
    func setEnabled(_ enabled: Bool, for kind: FilterKind) {
        if enabled { disabledFilters.remove(kind.rawValue) }
        else { disabledFilters.insert(kind.rawValue) }
    }

    /// Filters that should appear in the picker, in canonical order.
    var enabledFilters: [FilterKind] {
        FilterKind.allCases.filter { isEnabled($0) }
    }

    /// The author string to embed / watermark.
    var authorCredit: String {
        if !authorName.isEmpty && !authorHandle.isEmpty { return "\(authorName) (\(authorHandle))" }
        return authorName.isEmpty ? authorHandle : authorName
    }
}
