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

// MARK: - DuplicatesView (czkawka: exact duplicates + similar images, music, video)

struct DuplicatesView: View {
    var body: some View {
        UnavailableTab(
            title: "Duplicates",
            subtitle: "Exact duplicates by hash, plus similar images, music and video",
            icon: "doc.on.doc",
            reason: "This tab runs the bundled czkawka engine. Its output reader is still being wired up, so the tab stays empty for now instead of showing invented rows."
        )
    }
}

// MARK: - AppsView (Mole `uninstall`)

struct AppsView: View {
    var body: some View {
        UnavailableTab(
            title: "Apps",
            subtitle: "Uninstall an app together with its preferences, containers and launch agents",
            icon: "app.badge",
            reason: "The uninstall planner is not implemented yet. When it lands it will list every file it intends to remove, and keep data that another installed app still uses."
        )
    }
}

// MARK: - DiskView (Mole `analyze`)

struct DiskView: View {
    var body: some View {
        UnavailableTab(
            title: "Disk",
            subtitle: "Where the space went, largest first",
            icon: "internaldrive",
            reason: "The disk explorer is not implemented yet. Until then Finder shows the same information without guessing."
        )
    }
}
