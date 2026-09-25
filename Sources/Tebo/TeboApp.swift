import SwiftUI

// MARK: - TeboApp
// App entry point. Creates one shared AppState for all tabs.

@main
struct TeboApp: App {
    // One state object for the whole app (dry-run, whitelist, results).
    @State private var appState = AppState()

    init() {
        // Headless mode: `Tebo --selftest` reports what the app can see, then exits.
        // scripts/verify.sh and the audit harness drive this instead of the GUI.
        if SelfTest.isRequested {
            SelfTest.run()
            exit(0)
        }
        // `Tebo --benchmark[=N]` measures the scan pipeline's footprint. Async, so the
        // benchmark drives the run loop itself and exits when it is done.
        if let iterations = SelfTest.benchmarkIterations {
            Task {
                await SelfTest.benchmark(iterations: iterations)
                exit(0)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState) // Inject for all child views
                .frame(minWidth: 1020, minHeight: 680)
        }
        // Roomy default so tabs + stats + bottom bar never clip on launch.
        // contentMinSize stops the window shrinking below our min size.
        .defaultSize(width: 1240, height: 800)
        .windowResizability(.contentMinSize)
        // The app draws its own nav bar, so the title bar is hidden rather than duplicated.
        .windowStyle(.hiddenTitleBar)

        // The toolbar's SettingsLink() has nothing to open without this scene.
        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
