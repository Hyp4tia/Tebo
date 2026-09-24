import AppKit
import SwiftUI

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
    /// Fixers settings: which detection tool, and where it looks.
    @State private var fixerTool: CzkawkaTool = .invalidSymlinks
    @State private var fixerRoot: String = NSHomeDirectory()

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
                        return await CleanerService().findProjectArtifacts(whitelist: whitelist)
                    }
                )
            case .installers:
                ScanTab(
                    tabID: "installer",
                    title: "Installers",
                    subtitle: "DMG, PKG, ISO, XIP left in Downloads",
                    icon: "archivebox",
                    runScan: {
                        return await CleanerService().findInstallers(whitelist: whitelist)
                    }
                )
            case .fixers:
                ScanTab(
                    tabID: "fixers",
                    title: "Fixers",
                    subtitle: "Broken files, invalid symlinks, wrong extensions and messy names",
                    icon: "wrench.and.screwdriver",
                    runScan: { await runFixerScan() },
                    extraInfo: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Picker("Check", selection: $fixerTool) {
                                    ForEach(Self.fixerTools, id: \.self) { tool in
                                        Text(tool.displayName).tag(tool)
                                    }
                                }
                                .frame(maxWidth: 240)
                                Spacer()
                                Button("Choose folder…") { chooseFixerRoot() }
                                Text(fixerRoot)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Text("Finders only. The engine can also rewrite files in place, and SuperClean deliberately never passes that flag: anything you tick here moves to the Trash instead, so it stays reversible.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            AdvisoryList(note: appState.scanNote(for: "fixers"), advisories: [])
                        }
                    }
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

    // MARK: Fixers

    /// Detection tools offered in Fixers. The engine can also rewrite files in place (-F); that flag
    /// is deliberately not exposed anywhere in this app, because a rewrite is not reversible the way
    /// a Trash move is.
    private static let fixerTools: [CzkawkaTool] = [
        .invalidSymlinks, .brokenFiles, .wrongExtensions, .badNames,
    ]

    private func runFixerScan() async -> [ScanResult] {
        guard case .ready(let engineURL, _, _) = appState.engine else {
            appState.setScanNote("Engine not available — nothing was scanned.", for: "fixers")
            return []
        }
        var rows: [ScanResult] = []
        var failure: String?
        do {
            for try await item in CzkawkaBridge(engineURL: engineURL)
                .scan(tool: fixerTool, in: [URL(fileURLWithPath: fixerRoot)]) {
                rows.append(ScanResult(
                    id: item.id,
                    path: item.path,
                    sizeBytes: item.sizeBytes,
                    category: item.category,
                    reason: item.reason
                ))
            }
        } catch {
            failure = "\(fixerTool.displayName) scan failed: \(error.localizedDescription)"
        }
        appState.setScanNote(failure ?? "\(rows.count) findings under \(fixerRoot)", for: "fixers")
        return rows
    }

    private func chooseFixerRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: fixerRoot)
        panel.prompt = "Check here"
        if panel.runModal() == .OK, let picked = panel.url { fixerRoot = picked.path }
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
