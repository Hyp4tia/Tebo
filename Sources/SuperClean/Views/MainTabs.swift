import SwiftUI

// MARK: - CleanView (Mole `clean` + Krokiet temp/empty)
// First tab users see. Pure Swift, no Rust needed.

struct CleanView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Snapshot the whitelist now (Sendable value for the async scan).
        let whitelist = appState.whitelist
        ScanTab(
            tabID: "clean",
            title: "Smart Clean",
            subtitle: "Caches, logs, temp files — Mole clean + Krokiet temp",
            icon: "sparkles",
            runScan: {
                // Real per-app scan; mock fallback keeps the UI demoable
                // on machines where the safe locations are empty.
                let live = await CleanerService().previewSafeLocations(whitelist: whitelist)
                return live.isEmpty ? CzkawkaBridge.mockResults(for: "clean") : live
            }
        )
    }
}

// MARK: - DuplicatesView (Krokiet duplicates + similar media)
// Uses Rust engine in M3. Mock data in M1 so UI works today.

struct DuplicatesView: View {
    var body: some View {
        ScanTab(
            tabID: "duplicates",
            title: "Duplicates",
            subtitle: "Exact duplicates by hash — similar images/music/video in M3",
            icon: "doc.on.doc",
            runScan: {
                // M3: replace with CzkawkaBridge(engineURL: bundled).scanDuplicates()
                CzkawkaBridge.mockResults(for: "duplicates")
            }
        )
    }
}

// MARK: - AppsView (Mole `uninstall`)
// Lists /Applications + leftovers. M1 = mock, M2 = real inventory.

struct AppsView: View {
    var body: some View {
        ScanTab(
            tabID: "apps",
            title: "Apps",
            subtitle: "Uninstall apps + LaunchAgents, prefs, leftovers",
            icon: "app.badge",
            runScan: {
                CzkawkaBridge.mockResults(for: "apps")
            }
        )
    }
}

// MARK: - DiskView (Mole `analyze` + Krokiet big files)

struct DiskView: View {
    var body: some View {
        ScanTab(
            tabID: "disk",
            title: "Disk",
            subtitle: "Big files + disk explorer — largest first",
            icon: "internaldrive",
            runScan: {
                CzkawkaBridge.mockResults(for: "disk")
            }
        )
    }
}
