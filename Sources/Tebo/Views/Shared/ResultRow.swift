import AppKit
import SwiftUI

// MARK: - ResultRow
// One tickable finding: what it is (preview), where it lives (path), why it is safe (reason),
// how much it frees (size). Recommended rows say so on the row itself, so the reason for a
// default tick is never hidden in a menu.

struct ResultRow: View {
    let item: ScanResult
    let isSelected: Bool
    /// Bumped after a scan so stale previews are re-read.
    var refreshToken: Int = 0
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            FileThumb(path: item.path, side: 34, refreshToken: refreshToken)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.recommendedForSelection {
                        TeboBadge(text: "Recommended", systemImage: "sparkles", tint: .accentColor)
                    }
                }
                TeboPath(path: item.path)
                if !item.reason.isEmpty {
                    Text(item.reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            TeboNumber(text: item.displaySize, emphasis: isSelected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .contextMenu {
            Button("Copy Path") { NSPasteboard.general.copyString(item.path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
    }
}

// MARK: - Result section

/// Rows grouped under the table they came from, biggest group first, with its own totals.
struct ResultSection: View {
    let category: String
    let rows: [ScanResult]
    let isSelected: (ScanResult) -> Bool
    let refreshToken: Int
    let onToggle: (ScanResult) -> Void
    let onSelectCategory: (Bool) -> Void

    private var totalBytes: Int64 { rows.reduce(0) { $0 + $1.sizeBytes } }
    private var allSelected: Bool { rows.allSatisfy(isSelected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TeboSectionHeader(
                title: category,
                systemImage: "square.stack.3d.up",
                count: rows.count,
                sizeText: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            ) {
                Button(allSelected ? "Untick group" : "Tick group") { onSelectCategory(!allSelected) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal, 12)

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    ResultRow(
                        item: row,
                        isSelected: isSelected(row),
                        refreshToken: refreshToken
                    ) { onToggle(row) }
                    if row.id != rows.last?.id {
                        Divider().opacity(0.4).padding(.leading, 56)
                    }
                }
            }
            .teboCard(padding: 0)
        }
    }
}

extension NSPasteboard {
    func copyString(_ string: String) {
        clearContents()
        setString(string, forType: .string)
    }
}
