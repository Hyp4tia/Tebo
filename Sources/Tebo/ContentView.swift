import SwiftUI

// MARK: - ContentView
// Main window: 6 tabs merging Krokiet + Mole.
// Clean | Duplicates | Apps | Disk | Health | Toolbox

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Without Full Disk Access a scan silently sees less, so the gap is stated up front.
            if appState.hasFullDiskAccess == false {
                PermissionsBanner()
            }

            TabView {
                CleanView()
                    .tabItem { Label("Clean", systemImage: "sparkles") }
                DuplicatesView()
                    .tabItem { Label("Duplicates", systemImage: "doc.on.doc") }
                AppsView()
                    .tabItem { Label("Apps", systemImage: "app.badge") }
                DiskView()
                    .tabItem { Label("Disk", systemImage: "internaldrive") }
                HealthView()
                    .tabItem { Label("Health", systemImage: "heart.text.square") }
                ToolboxView()
                    .tabItem { Label("Toolbox", systemImage: "wrench.and.screwdriver") }
            }
            .toolbar {
                // The single control for delete behaviour; Settings explains it, never duplicates it.
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Dry-run", isOn: Binding(
                        get: { appState.dryRunEnabled },
                        set: { appState.dryRunEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .help("When on, scans only preview. Nothing is deleted.")
                }
                ToolbarItem {
                    SettingsLink()
                }
            }
        }
        // Engine verification and the permission probe each cost a disk read: once per launch.
        .task { await appState.refreshTooling() }
    }
}
