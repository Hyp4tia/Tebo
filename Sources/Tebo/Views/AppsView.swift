import SwiftUI

// MARK: - AppsView (Mole `uninstall`)
// What removed apps left behind, grouped by the app it belongs to, with the app's real icon when
// its bundle can still be found. The app bundle itself is NOT moved from here: SafetyGate refuses
// /Applications, so removing an app stays the user's action in Finder.

struct AppsView: View {
    @Environment(AppState.self) private var appState

    @State private var keptRows: [AdvisoryRow] = []
    @State private var expandedOwners: Set<String> = []

    var body: some View {
        ScanTab(
            tabID: "apps",
            title: "Apps",
            subtitle: "What removed apps left behind, grouped by the app it came from",
            icon: "app.badge",
            recommendedExplanation: "Leftovers nothing has touched in over a year. Anything newer stays listed but unticked.",
            rowsOverride: { rows in AnyView(ownerCards(rows)) },
            runScan: { await runScan() },
            extraInfo: {
                HStack(spacing: 8) {
                    TeboBadge(text: "Bundles stay yours", systemImage: "hand.point.up.left", tint: .secondary)
                    Text("Removing an app itself is a Finder action. This tab is what it leaves behind.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ReviewPanel(note: appState.scanNote(for: "apps"), advisories: keptRows)
            }
        )
    }

    /// One card per owner, biggest total first, so the tab opens on what is worth doing.
    @ViewBuilder
    private func ownerCards(_ rows: [ScanResult]) -> some View {
        let grouped = Dictionary(grouping: rows) { OrphanOwner.key(forPath: $0.path) }
        let ordered = grouped
            .map { (owner: $0.key, rows: $0.value) }
            .sorted { left, right in
                left.rows.reduce(0) { $0 + $1.sizeBytes } > right.rows.reduce(0) { $0 + $1.sizeBytes }
            }

        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(ordered, id: \.owner) { entry in
                AppLeftoverCard(
                    ownerKey: entry.owner,
                    rows: entry.rows.sorted { $0.sizeBytes > $1.sizeBytes },
                    isExpanded: Binding(
                        get: { expandedOwners.contains(entry.owner) },
                        set: { isOpen in
                            if isOpen { expandedOwners.insert(entry.owner) }
                            else { expandedOwners.remove(entry.owner) }
                        }
                    )
                )
            }
        }
    }

    private func runScan() async -> [ScanResult] {
        let report = await OrphanScanner(configuration: .defaults()).scan()

        // Everything the scanner decided to keep is shown as an advisory: a leftover list that
        // silently drops its uncertain cases would read as "this Mac is clean" when it is not.
        keptRows = report.kept.map { row in
            AdvisoryRow(
                id: row.id.uuidString,
                title: row.name,
                detail: row.reason,
                source: "kept: \(row.path)"
            )
        }

        let note = report.orphans.isEmpty
            ? "No leftovers found that clearly belong to a removed app."
            : "\(report.orphans.count) leftovers, \(report.displayTotalBytes) total. \(report.kept.count) entries kept back."
        appState.setScanNote(note, for: "apps")

        // A year of silence is the only signal available for "nobody will miss this": anything the
        // app touched more recently stays listed but is never ticked by a button.
        let oneYearAgo = Date.now.addingTimeInterval(-365 * 86_400)
        return report.orphans.map { row in
            ScanResult(
                path: row.path,
                sizeBytes: row.sizeBytes,
                category: row.category.rawValue,
                reason: row.reason,
                recommendedForSelection: (row.lastModified.map { $0 < oneYearAgo }) ?? false
            )
        }
    }
}
