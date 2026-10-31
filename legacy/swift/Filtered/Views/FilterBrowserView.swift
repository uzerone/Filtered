import SwiftUI

/// A plain button representing one filter in the picker. No special tile UI —
/// just a labeled button that adds the filter as a new layer.
struct FilterTile: View {
    let kind: FilterKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(kind.displayName)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(kind.displayName)
    }
}
