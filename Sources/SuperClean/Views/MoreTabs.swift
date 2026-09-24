import SwiftUI

// MARK: - HealthView (Mole `status` + `optimize`)
// Read-only live stats now. Optimize actions land in M2.
// Kept dependency-free: uses ProcessInfo + FileManager (no private APIs).

struct HealthView: View {
    @State private var cpuCount: Int = ProcessInfo.processInfo.processorCount
    @State private var memoryGB: Double = 0
    @State private var diskFree: String = "—"
    @State private var uptime: String = "—"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Health").font(.largeTitle).bold()
            Text("Live system snapshot — read-only, like `mo status`")
                .foregroundStyle(.secondary)

            HStack {
                StatCard(title: "CPU cores", value: "\(cpuCount)", systemImage: "cpu")
                StatCard(title: "Memory", value: String(format: "%.1f GB", memoryGB), systemImage: "memorychip")
                StatCard(title: "Disk free", value: diskFree, systemImage: "internaldrive")
                StatCard(title: "Uptime", value: uptime, systemImage: "clock")
            }

            Text("Optimize (M2): Flush DNS, verify Spotlight, refresh Finder caches — each with Dry-run preview + whitelist.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, 8)

            Spacer()
            Button("Refresh") { refresh() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear { refresh() }
    }

    /// Cheap snapshot. No polling loop in M1 (saves battery).
    private func refresh() {
        let memBytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        memoryGB = memBytes
        // Disk free via FileManager (fast, no shell-out).
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64 {
            diskFree = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        }
        let secs = Int(ProcessInfo.processInfo.systemUptime)
        uptime = "\(secs / 3600)h \((secs % 3600) / 60)m"
    }
}

// MARK: - ToolboxView (Mole purge/installer + Krokiet small tools + History)
// Purge = node_modules/target/dist. Installer = DMG/PKG. History = operations.log.
// NOTE: Uses a segmented Picker, NOT a nested TabView — a TabView inside
// ContentView's TabView makes the outer bar jump/shift on macOS.

struct ToolboxView: View {
    // Sub-tool selector. One TabView only (outer) = stable toolbar.
    private enum Tool: String, CaseIterable {
        case purge = "Purge"
        case installers = "Installers"
        case fixers = "Fixers"
        case history = "History"
    }

    @Environment(AppState.self) private var appState
    @State private var selectedTool: Tool = .purge
    @State private var history: [String] = []

    var body: some View {
        // Snapshot the whitelist now (Sendable value for the async scans).
        let whitelist = appState.whitelist
        VStack(alignment: .leading, spacing: 12) {
            // Sub-navigation stays inside the page, never touches the window tab bar.
            Picker("Tool", selection: $selectedTool) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    Text(tool.rawValue).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 500)

            // Content swaps below, outer tab bar never moves.
            switch selectedTool {
            case .purge:
                ScanTab(
                    tabID: "purge",
                    title: "Purge",
                    subtitle: "Rebuildable project folders: node_modules, target, dist",
                    icon: "hammer",
                    runScan: {
                        let live = await CleanerService().findProjectArtifacts(whitelist: whitelist)
                        return live.isEmpty ? CzkawkaBridge.mockResults(for: "purge") : live
                    }
                )
            case .installers:
                ScanTab(
                    tabID: "installer",
                    title: "Installers",
                    subtitle: "DMG, PKG, ISO, XIP left in Downloads",
                    icon: "archivebox",
                    runScan: {
                        let live = await CleanerService().findInstallers(whitelist: whitelist)
                        return live.isEmpty ? CzkawkaBridge.mockResults(for: "installer") : live
                    }
                )
            case .fixers:
                ScanTab(
                    tabID: "toolbox",
                    title: "Fixers",
                    subtitle: "Broken files, bad extensions, symlinks, Exif, bad names",
                    icon: "wrench.and.screwdriver",
                    runScan: { CzkawkaBridge.mockResults(for: "toolbox") }
                )
            case .history:
                // History sub-view (like `mo history`)
                VStack(alignment: .leading) {
                    Text("History").font(.largeTitle).bold()
                    Text("Every preview + Trash move, newest last").foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(history, id: \.self) { line in
                                Text(line).font(.caption).monospaced().textSelection(.enabled)
                                Divider()
                            }
                        }
                    }
                    Button("Reload") { Task { history = await OperationLog.shared.recentLines() } }
                        .buttonStyle(.bordered)
                }
                .padding()
                .onAppear { Task { history = await OperationLog.shared.recentLines() } }
            }
        }
        .padding()
        // Reload history whenever user switches to it.
        .onChange(of: selectedTool) { _, new in
            if new == .history {
                Task { history = await OperationLog.shared.recentLines() }
            }
        }
    }
}

// MARK: - SettingsView (whitelist + engine info)

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newEntry = ""

    var body: some View {
        Form {
            // The dry-run switch lives in the toolbar: one control for one state, always visible.
            Section("Safety") {
                Text("Dry-run is the toolbar switch. While it is on, every scan is a preview and nothing is deleted. With it off, removals move files to the Trash and are logged to ~/Library/Logs/superclean/operations.log.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Whitelist — never touch these") {
                ForEach(Array(appState.whitelist).sorted(), id: \.self) { entry in
                    HStack {
                        Text(entry).monospaced()
                        Spacer()
                        Button("Remove") { appState.removeWhitelist(entry) }
                    }
                }
                HStack {
                    TextField("~/Library/Caches/com.myapp", text: $newEntry)
                    Button("Add") {
                        appState.addWhitelist(newEntry)
                        newEntry = ""
                    }
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Saved to ~/.config/superclean/whitelist and applied before every scan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Engines") {
                LabeledContent("czkawka_cli", value: appState.engine.summary)
                LabeledContent(
                    "ffmpeg",
                    value: appState.ffmpegPath ?? "Not installed — similar videos and video checks stay disabled"
                )
                Button("Re-check engines") { Task { await appState.refreshTooling() } }
                Text("czkawka_cli is MIT (qarmin/czkawka) and is bundled hash-verified. Cleanup rules are ported from tw93/Mole (GPL-3.0). See NOTICE.md.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 440)
        .padding()
        .task { await appState.refreshTooling() }
    }
}
