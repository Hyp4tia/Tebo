import SwiftUI

// MARK: - SuperCleanApp
// App entry point. Creates one shared AppState for all tabs.

@main
struct SuperCleanApp: App {
    // One state object for the whole app (dry-run, whitelist, results).
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState) // Inject for all child views
                .frame(minWidth: 1020, minHeight: 680)
        }
        // Roomy default so tabs + stats + bottom bar never clip on launch.
        // contentMinSize stops the window shrinking below our min size.
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        // The toolbar's SettingsLink() has nothing to open without this scene.
        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
