import SwiftUI

// MARK: - AppsView (Mole `uninstall`)
// Finds leftovers that no longer belong to an installed app, and states plainly what it kept and
// why. The app bundle itself is NOT moved from here: SafetyGate refuses /Applications, so removing
// an app stays the user's action in Finder and this tab cleans up what the app left behind.

struct AppsView: View {
    @Environment(AppState.self) private var appState

    @State private var keptRows: [AdvisoryRow] = []

    var body: some View {
        ScanTab(
            tabID: "apps",
            title: "Apps",
            subtitle: "Leftovers from apps you removed, with anything uncertain left alone",
            icon: "app.badge",
            runScan: { await runScan() },
            extraInfo: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("To remove an app itself, drag it from Applications to the Trash. This tab handles what it leaves behind.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    AdvisoryList(note: appState.scanNote(for: "apps"), advisories: keptRows)
                }
            }
        )
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

        return report.orphans.map { row in
            ScanResult(
                path: row.path,
                sizeBytes: row.sizeBytes,
                category: row.category.rawValue,
                reason: row.reason
            )
        }
    }
}
