import SwiftUI

/// The app's Settings window (⌘,) — General/export, Fonts, Filters, About.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            FontSettings()
                .tabItem { Label("Font", systemImage: "textformat") }
            FilterSettings()
                .tabItem { Label("Filters", systemImage: "camera.filters") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - General / Author / Export

private struct GeneralSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Author") {
                TextField("Name", text: $settings.authorName)
                TextField("Handle", text: $settings.authorHandle, prompt: Text("@yourhandle"))
                Text("Embedded in export metadata or used as a watermark.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Export") {
                Toggle("Embed author metadata in exports", isOn: $settings.embedAuthorMetadata)
                Toggle("Add watermark", isOn: $settings.addWatermark)
                if settings.addWatermark {
                    TextField("Watermark text", text: $settings.watermarkText,
                              prompt: Text(settings.authorCredit.isEmpty ? "Filtered" : settings.authorCredit))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Fonts

private struct FontSettings: View {
    @State private var fonts = FontManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Imported Fonts").font(.headline)
                Spacer()
                Button {
                    fonts.importFonts()
                } label: { Label("Import Font…", systemImage: "plus") }
            }

            if fonts.importedFontFiles.isEmpty {
                ContentUnavailableView("No imported fonts",
                                       systemImage: "textformat",
                                       description: Text("Click \"Import Font…\" to add .ttf / .otf / .ttc files.\n\(fonts.families.count) system fonts are ready to use."))
            } else {
                List(fonts.importedFontFiles.indices, id: \.self) { i in
                    let f = fonts.importedFontFiles[i]
                    HStack {
                        Image(systemName: "textformat.characters")
                            .foregroundStyle(.secondary)
                        Text(f.name)
                        Spacer()
                    }
                }
                Text("\(fonts.families.count) fonts available (including system fonts).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Filter management

private struct FilterSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visible Filters")
                .font(.headline)
            Text("Uncheck to hide a filter from the Add Filter list.")
                .font(.caption).foregroundStyle(.secondary)

            List {
                ForEach(FilterFamily.allCases) { family in
                    Section(family.displayName) {
                        ForEach(FilterKind.allCases.filter { $0.family == family }) { kind in
                            Toggle(isOn: Binding(
                                get: { settings.isEnabled(kind) },
                                set: { settings.setEnabled($0, for: kind) }
                            )) {
                                Text(kind.displayName)
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Enable All") {
                    settings.disabledFilters.removeAll()
                }
                Spacer()
                Text("\(settings.enabledFilters.count)/\(FilterKind.allCases.count) enabled")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable().frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(LinearGradient(colors: [.indigo, .blue, .teal],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                    .overlay(Text("F").font(.system(size: 54, weight: .bold)).foregroundStyle(.white))
            }
            Text("Filtered").font(.title.bold())
            Text("Fast filtering for images & designs")
                .font(.callout).foregroundStyle(.secondary)
            Divider().frame(width: 200)
            VStack(spacing: 4) {
                Text("Made by JYEU@CTRLP")
                    .font(.callout)
                Text("Fast filtering for images & designs")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Version 1.0")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }
}
