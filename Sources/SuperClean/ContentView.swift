import SwiftUI

// MARK: - ContentView
// Main window: 6 tabs merging Krokiet + Mole.
// Clean | Duplicates | Apps | Disk | Health | Toolbox

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
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
            // Global dry-run toggle — always visible so user feels safe.
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
}
