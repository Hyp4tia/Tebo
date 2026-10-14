import AppKit
import SwiftUI

// MARK: - ToolboxView (Mole purge/installer + Krokiet small tools + History)
// Purge = node_modules/target/dist. Installer = DMG/PKG. History = operations.log.
// NOTE: Sub-tools are a pill row, not a nested TabView: a TabView inside
// ContentView's TabView makes the outer bar jump/shift on macOS.

struct ToolboxView: View {
    // Sub-tool selector. One TabView only (outer) = stable toolbar.
    private enum Tool: String, CaseIterable {
        case purge = "Purge"
        case installers = "Installers"
        case fixers = "Fixers"
        case history = "History"

        // The same symbol each tool's ScanTab header uses, so the picker and its content agree.
        var symbol: String {
            switch self {
            case .purge: "hammer"
            case .installers: "archivebox"
            case .fixers: "wrench.and.screwdriver"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @State private var selectedTool: Tool = .purge
    @State private var history: [String] = []
    /// Fixers settings: which detection tool, and where it looks.
    @State private var fixerTool: CzkawkaTool = .invalidSymlinks
    @State private var fixerRoot: String = NSHomeDirectory()

    init(initialTool: String = "Purge") {
        _selectedTool = State(initialValue: Tool(rawValue: initialTool) ?? .purge)
    }

    var body: some View {
        // Snapshot the whitelist now (Sendable value for the async scans).
        let whitelist = appState.whitelist
        VStack(alignment: .leading, spacing: 12) {
            // Sub-navigation stays inside the page, never touches the window tab bar.
            HStack(spacing: 4) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    TeboPill(
                        title: tool.rawValue,
                        systemImage: tool.symbol,
                        isActive: selectedTool == tool
                    ) {
                        selectedTool = tool
                    }
                }
            }

            // Content swaps below, outer tab bar never moves.
            switch selectedTool {
            case .purge:
                ScanTab(
                    tabID: "purge",
                    title: "Purge",
                    subtitle: "Rebuildable project folders: node_modules, target, dist",
                    icon: "hammer",
                    removalValidator: { await ProjectArtifactScanner().protectionReason(for: URL(fileURLWithPath: $0), whitelist: whitelist) },
                    runScan: {
                        return await CleanerService().findProjectArtifacts(whitelist: whitelist)
                    },
                    extraInfo: { Text("Repositories, tracked files and deployment keys stay protected.").font(.caption).foregroundStyle(.secondary) }
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
                                TeboPath(path: fixerRoot)
                            }
                            HStack(spacing: 6) {
                                TeboBadge(text: "Finder only", systemImage: "eye", tint: .secondary)
                                Text("Anything you tick moves to the Trash, never rewritten in place.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ReviewPanel(note: appState.scanNote(for: "fixers"), advisories: [])
                        }
                    }
                )
            case .history:
                // History sub-view (like `mo history`)
                VStack(alignment: .leading, spacing: 10) {
                    TeboSectionHeader(title: "History", systemImage: "clock.arrow.circlepath") {
                        TeboBadge(text: "\(history.count)")
                        Button {
                            Task { history = await OperationLog.shared.recentLines() }
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(TeboButtonStyle())
                        .controlSize(.small)
                    }
                    Text("Every preview + Trash move, newest last")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if history.isEmpty {
                        TeboEmptyState(
                            systemImage: "clock.arrow.circlepath",
                            title: "Nothing logged yet",
                            message: "Preview and Trash moves appear here."
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading) {
                                ForEach(history, id: \.self) { line in
                                    Text(line).font(.caption).monospaced().textSelection(.enabled)
                                    Divider()
                                }
                            }
                        }
                    }
                }
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
            appState.setScanNote("Engine not available: nothing was scanned.", for: "fixers")
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
    @Environment(AppUpdater.self) private var updater
    @State private var newEntry = ""
    @Environment(TeboAppearanceSettings.self) private var appearance

    var body: some View {
        @Bindable var appearance = appearance
        Form {
            if updater.isAvailable {
                Section("Updates") {
                    Text(updater.versionText).font(.callout)
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    Text("Updates are delivered from Tebo's GitHub releases.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Appearance") {
                TeboArtworkBackground()
                    .frame(height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(TeboPalette.line, lineWidth: 1) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Background blur")
                        Spacer()
                        Text("\(Int(appearance.backgroundBlur))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $appearance.backgroundBlur, in: 0...50, step: 1) {
                        Text("Background blur")
                    } minimumValueLabel: {
                        Text("Sharp").font(.caption)
                    } maximumValueLabel: {
                        Text("Soft").font(.caption)
                    }
                    .labelsHidden()
                    .accessibilityLabel("Background blur")
                    Text("Softens the artwork behind the workspace. Controls and text stay sharp.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
            }
            // The dry-run switch lives in the toolbar: one control for one state, always visible.
            Section("Safety") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Preview only", isOn: Binding(get: { appState.dryRunEnabled }, set: { appState.dryRunEnabled = $0 }))
                    Text("On: cleanup, uninstall and maintenance actions are previews. Nothing is changed.")
                    Text("Off: removals move files to the Trash and are logged to ~/Library/Logs/tebo/operations.log.")
                }
                .font(.callout)
            }
            Section("Whitelist: never touch these") {
                ForEach(Array(appState.whitelist).sorted(), id: \.self) { entry in
                    HStack {
                        TeboPath(path: entry)
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
                Text("Saved to ~/.config/tebo/whitelist and applied before every scan.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Action names such as cache_refresh also protect maintenance tasks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Engines") {
                LabeledContent("czkawka_cli", value: appState.engine.summary)
                LabeledContent(
                    "ffmpeg",
                    value: appState.ffmpegPath ?? "Not installed: similar videos and video checks stay disabled"
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
