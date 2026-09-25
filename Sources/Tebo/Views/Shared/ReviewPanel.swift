import AppKit
import SwiftUI

// MARK: - ReviewGrouping
// Presentation-only grouping for entries a scanner deliberately kept back. The reasons are free
// text from two producers (the Mole tables and the orphan scanner), so this maps them to a small
// set of headings. Grouping is a view concern: no scanner decides anything here, and nothing in
// this panel can ever be selected for deletion.

enum ReviewGrouping {
    /// Ordered: the first matching rule wins, so the specific cases come first.
    /// Keywords are matched against the lowercased reason.
    private static let rules: [(label: String, keywords: [String])] = [
        ("macOS system components", ["apple system"]),
        ("Used by an installed app", [
            "belongs to installed app", "owned by an installed app", "installed app owns",
        ]),
        ("Modified recently", ["retention window", "modified within"]),
        ("Its program is missing", ["no longer exists"]),
        ("In use right now", ["running"]),
        ("Ownership could not be proven", [
            "unreadable", "could not verify", "cannot be proven", "not a bundle identifier",
            "no absolute program path", "no bundle identifier", "bundle lookup unavailable",
            "no label",
        ]),
        ("Needs administrator rights", ["admin", "root", "sudo"]),
        ("Reported only, nothing to delete", ["report"]),
    ]

    static let fallback = "Other entries kept"

    /// Heading for one entry's explanation.
    static func group(for reason: String) -> String {
        let lowered = reason.lowercased()
        for rule in rules where rule.keywords.contains(where: lowered.contains) {
            return rule.label
        }
        return fallback
    }

    /// What heading an entry goes under: what its producer said when it knew, otherwise what its
    /// wording implies. Producers win because they know the reason, not just the sentence.
    static func heading(for row: AdvisoryRow) -> String {
        row.group.isEmpty ? group(for: row.reasonPhrase) : row.group
    }

    /// One heading's worth of entries.
    struct Group: Identifiable {
        let title: String
        let rows: [AdvisoryRow]
        var id: String { title }
    }

    /// Sections for the review panel: biggest groups first, rows alphabetical inside a group.
    static func groups(from rows: [AdvisoryRow]) -> [Group] {
        let grouped = Dictionary(grouping: rows) { heading(for: $0) }
        return grouped
            .map { Group(title: $0.key, rows: $0.value.sorted { $0.title.lowercased() < $1.title.lowercased() }) }
            .sorted {
                $0.rows.count == $1.rows.count
                    ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    : $0.rows.count > $1.rows.count
            }
    }
}

// MARK: - ReviewPanel

/// The quiet card that replaces a disclosure list of kept-back entries. The full list lives in a
/// sheet with lazy rows: a scan can keep back hundreds of entries, and building them inline
/// froze the window.
struct ReviewPanel: View {
    let note: String?
    let advisories: [AdvisoryRow]

    @State private var isPresented = false

    var body: some View {
        if note != nil || !advisories.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.callout.weight(.medium))
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if !advisories.isEmpty {
                    Button("Review \(advisories.count)…") { isPresented = true }
                        .buttonStyle(.bordered)
                        .help("Open the full list of entries that were kept back, and why")
                }
            }
            .teboCard(padding: 12)
            .sheet(isPresented: $isPresented) {
                ReviewSheet(advisories: advisories)
            }
        }
    }

    private var headline: String {
        advisories.isEmpty
            ? "Nothing was held back"
            : "\(advisories.count) entries kept back from deletion"
    }
}

// MARK: - ReviewSheet

private struct ReviewSheet: View {
    let advisories: [AdvisoryRow]

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var expanded: Set<String> = []

    /// Rows shown before a group has to be expanded: keeping the first paint small is what makes
    /// the panel open instantly even with hundreds of entries.
    private let previewLimit = 25

    private var filtered: [AdvisoryRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return advisories }
        return advisories.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.detail.localizedCaseInsensitiveContains(trimmed)
                || $0.source.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(ReviewGrouping.groups(from: filtered)) { group in
                            groupSection(group)
                        }
                    }
                    .padding(16)
                }

                if filtered.isEmpty {
                    TeboEmptyState(
                        systemImage: "magnifyingglass",
                        title: "No entry matches",
                        message: "Nothing here matches \"\(query)\"."
                    )
                }

                Divider()

                HStack {
                    Text("These entries are never selectable, and this panel can not delete anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }
            .navigationTitle("Kept back (\(advisories.count))")
            .searchable(text: $query, placement: .toolbar, prompt: "Filter kept-back entries")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 660, idealWidth: 720, minHeight: 460, idealHeight: 540)
    }

    @ViewBuilder
    private func groupSection(_ group: ReviewGrouping.Group) -> some View {
        let isExpanded = expanded.contains(group.title)
        let visible = isExpanded ? group.rows : Array(group.rows.prefix(previewLimit))

        VStack(alignment: .leading, spacing: 6) {
            TeboSectionHeader(
                title: group.title,
                systemImage: isExpanded ? "chevron.down" : "chevron.right",
                count: group.rows.count
            )

            VStack(alignment: .leading, spacing: 1) {
                ForEach(visible) { row in
                    rowView(row)
                    if row.id != visible.last?.id { Divider().opacity(0.5) }
                }
            }
            .teboCard(padding: 0)
            .padding(.horizontal, 0)

            if group.rows.count > previewLimit {
                Button(isExpanded ? "Show first \(previewLimit)" : "Show all \(group.rows.count)") {
                    if isExpanded { expanded.remove(group.title) } else { expanded.insert(group.title) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private func rowView(_ row: AdvisoryRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if row.pathForThumb.isEmpty {
                Image(systemName: "text.book.closed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, height: 26)
            } else {
                FileThumb(path: row.pathForThumb, side: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.callout)
                    .lineLimit(1)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.source.isEmpty {
                    Text(row.source)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.source)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Path") { NSPasteboard.general.copyString(row.pathForThumb) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.pathForThumb)])
            }
        }
    }
}
