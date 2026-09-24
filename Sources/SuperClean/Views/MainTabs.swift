import SwiftUI

// MARK: - CleanView (Mole `clean`)
// First tab users see. Real sweep of Mole's ported tables: every row is a path that exists on this
// Mac right now, measured on the spot.

struct CleanView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Snapshot what the scan needs so the closure captures values, not view state.
        let whitelist = appState.whitelist
        // NSWorkspace must be read on the main actor; the sweep itself runs off it.
        let running = TargetScanner.liveRunningProcessNames()

        ScanTab(
            tabID: "clean",
            title: "Smart Clean",
            subtitle: "Caches, logs and leftovers, biggest first",
            icon: "sparkles",
            runScan: {
                let outcome = await TargetScanner(runningProcessNames: running)
                    .scan(whitelist: whitelist)
                appState.apply(outcome, to: "clean")
                return outcome.deletable
            },
            extraInfo: {
                AdvisoryList(
                    note: appState.scanNote(for: "clean"),
                    advisories: appState.advisories(for: "clean")
                )
            }
        )
    }
}

// MARK: - Other tabs
// DuplicatesView (czkawka engine) and AppsView/DiskView/HealthView each live in their own file.

