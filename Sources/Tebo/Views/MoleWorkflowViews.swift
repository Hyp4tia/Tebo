import AppKit
import SwiftUI

struct MolePurgeView: View {
    @Environment(AppState.self) private var appState
    @State private var roots = MolePaths.projectSearchRoots
    @AppStorage("filecleanup.purge.roots") private var savedRoots = ""
    var body: some View {
        let scanner = ProjectArtifactScanner(roots: roots)
        let whitelist = appState.whitelist
        ScanTab(tabID: "purge", title: "Project Cleanup", subtitle: "Build outputs and dependencies that can be rebuilt", icon: "hammer",
            scanScope: roots,
            recommendedExplanation: "Only artifacts with no file activity in the last 7 days. Recent or unknown activity stays unticked.",
            removalValidator: { await scanner.protectionReason(for: URL(fileURLWithPath: $0), whitelist: whitelist) },
            runScan: {
                let found = await scanner.scan(whitelist: appState.whitelist)
                guard !Task.isCancelled else { return [] }
                appState.advisoriesByTab["purge"] = found.kept
                appState.setScanNote(found.partial ? "Scan stopped early; some projects were not checked." : "\(found.rows.count) rebuildable \(found.rows.count == 1 ? "folder" : "folders") found.", for: "purge")
                return found.rows
            }, extraInfo: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(roots.count) project \(roots.count == 1 ? "location" : "locations")").font(.callout.weight(.medium))
                        Spacer()
                        Button("Choose folders…") { chooseRoots() }
                    }
                    Text(roots.isEmpty ? "Choose a folder containing your projects." : roots.map { TeboPath.abbreviate($0) }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text("Repositories, tracked files, deployment keys and vendored source stay protected. Worktree folders are never removed.")
                        .font(.caption).foregroundStyle(.secondary)
                    ReviewPanel(note: appState.scanNote(for: "purge"), advisories: appState.advisories(for: "purge"))
                }.teboCard()
            })
        .onAppear {
            if let data = savedRoots.data(using: .utf8), let saved = try? JSONDecoder().decode([String].self, from: data), !saved.isEmpty {
                roots = saved
            }
        }
    }
    private func chooseRoots() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = true
        picker.prompt = "Use these folders"
        if picker.runModal() == .OK {
            roots = picker.urls.map(\.path)
            if let data = try? JSONEncoder().encode(roots) { savedRoots = String(data: data, encoding: .utf8) ?? "" }
        }
    }
}

struct MoleInstallerView: View {
    @Environment(AppState.self) private var appState
    @State private var customRoots: [String] = []
    @State private var kept: [AdvisoryRow] = []
    var body: some View {
        ScanTab(tabID: "installer", title: "Installers", subtitle: "Downloaded installers, with their size and source", icon: "arrow.down.app",
            recommendedExplanation: "Installers older than 30 days. Recent downloads stay unticked.", runScan: {
                var configuration = InstallerScanConfiguration.defaults()
                if !customRoots.isEmpty { configuration.searchRoots = customRoots }
                let files = await InstallerFinder(configuration: configuration).findInstallers()
                kept = files.filter { !SafetyGate.isAllowed(path: $0.path, whitelist: appState.whitelist) }.map {
                    .init(id: $0.path, title: $0.name, detail: "Protected by your whitelist or system rules", source: $0.path)
                }
                appState.setScanNote("\(files.count) installers found across \(configuration.searchRoots.count) search locations.", for: "installer")
                return files.map {
                    ScanResult(id: $0.id, path: $0.path, sizeBytes: $0.sizeBytes, category: $0.source,
                        reason: "\($0.kind.rawValue.uppercased()) installer",
                        recommendedForSelection: ($0.age ?? 0) > 30 * 86_400)
                }
            }, extraInfo: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(customRoots.isEmpty ? "Standard download locations" : "\(customRoots.count) selected folders")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button("Choose folders…") { chooseRoots() }
                    }
                    Text("DMG, PKG, MPKG, ISO, XIP and ZIP files that contain an installer. Ordinary ZIP archives are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                    ReviewPanel(note: appState.scanNote(for: "installer"), advisories: kept)
                }.teboCard()
            })
    }
    private func chooseRoots() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = true
        if picker.runModal() == .OK { customRoots = picker.urls.map(\.path) }
    }
}

struct NativeAnalyzeView: View {
    @Environment(AppState.self) private var appState
    @State private var requestScan = false
    @Environment(\.workspaceSearch) private var search
    private var root: String { appState.analysisRoot }
    private var analysis: FolderAnalysis? { appState.folderAnalysis }
    var body: some View {
        ScanTab(tabID: "analyze", title: "Analyze", subtitle: "Explore disk usage, one folder at a time", icon: "chart.pie",
            foundLabel: "Selectable", sizeLabel: "Selectable size", emptyMessage: "Choose a folder to see its measured disk usage. Exploring never removes files.",
            scanScope: [root],
            rowsOverride: { AnyView(entries(allowed: $0)) }, rescanRequested: $requestScan,
            rendersEmptyRowsOverride: true, runScan: {
                let found = await NativeDiskAnalyzer().analyze(root)
                guard !Task.isCancelled else { return [] }
                appState.folderAnalysis = found
                let note = found.status == .unavailable ? "This folder could not be read."
                    : found.status == .partial ? "Partial scan: sizes marked ≥ are lower bounds. Protected entries are read-only."
                    : "\(found.entries.count) \(found.entries.count == 1 ? "entry" : "entries") measured. Protected entries are read-only."
                appState.setScanNote(note, for: "analyze")
                appState.advisoriesByTab["analyze"] = found.entries.filter {
                    $0.measurement.status == .unavailable || !SafetyGate.isAllowed(path: $0.path, whitelist: appState.whitelist)
                }.map {
                    AdvisoryRow(id: $0.path, title: URL(fileURLWithPath: $0.path).lastPathComponent,
                        detail: $0.measurement.status == .unavailable ? "Unreadable entry: kept" : "Protected location: read only", source: $0.path)
                }
                return found.entries.filter { $0.measurement.status != .unavailable }.map {
                    ScanResult(path: $0.path, sizeBytes: $0.measurement.bytes,
                        category: $0.isDirectory ? "Folders" : "Files", reason: "Measured in \(TeboPath.abbreviate(root))",
                        isSizeComplete: $0.measurement.status == .complete)
                }
            }, extraInfo: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button { appState.analysisRoot = URL(fileURLWithPath: root).deletingLastPathComponent().path; requestScan = true } label: {
                            Image(systemName: "arrow.up")
                        }.disabled(root == "/")
                        TeboPath(path: root)
                        Spacer()
                        Button("Choose folder…") { chooseRoot() }
                    }
                    if let analysis {
                        HStack {
                            Text("\(analysis.entries.count) \(analysis.entries.count == 1 ? "entry" : "entries")")
                            Spacer()
                            Text("\(analysis.status == .complete ? "" : "≥ ")\(TeboBytes.text(analysis.bytes)) measured")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    ReviewPanel(note: appState.scanNote(for: "analyze"), advisories: appState.advisories(for: "analyze"))
                }.teboCard()
            })
    }

    private func entries(allowed: [ScanResult]) -> some View {
        let rows = Dictionary(uniqueKeysWithValues: allowed.map { ($0.path, $0) })
        let visible = analysis?.entries.filter {
            (search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)) && (rows[$0.path] != nil
                || !SafetyGate.isAllowed(path: $0.path, whitelist: appState.whitelist)
                || $0.measurement.status == .unavailable)
        } ?? []
        return LazyVStack(spacing: 8) {
            if visible.isEmpty {
                TeboEmptyState(systemImage: "folder", title: "No readable matching entries",
                               message: "Choose another folder or change your search.")
            }
            ForEach(visible) { entry in
                let row = rows[entry.path]
                HStack(spacing: 12) {
                    Toggle("Select \(URL(fileURLWithPath: entry.path).lastPathComponent)", isOn: Binding(
                        get: { row.map { appState.selectedIDs.contains($0.id) } ?? false },
                        set: { _ in if let row { appState.toggleSelection(row.id) } }))
                        .toggleStyle(.checkbox).labelsHidden().disabled(row == nil)
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isDirectory ? TeboPalette.blue : TeboPalette.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(URL(fileURLWithPath: entry.path).lastPathComponent).font(.callout.weight(.medium))
                        if row == nil { Text("Read only").font(.caption2).foregroundStyle(.secondary) }
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 2).fill(TeboPalette.blue.opacity(0.25))
                                .frame(width: geometry.size.width * min(1, Double(entry.measurement.bytes) / Double(max(1, analysis?.bytes ?? 1))))
                        }.frame(height: 4)
                    }
                    Spacer()
                    Text(entry.measurement.status == .unavailable ? "Unreadable"
                         : (entry.measurement.status == .complete ? "" : "≥ ") + TeboBytes.text(entry.measurement.bytes))
                        .font(.caption).monospacedDigit()
                    if entry.isDirectory {
                        Button { appState.analysisRoot = entry.path; requestScan = true } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain).help("Explore this folder")
                    }
                }.teboCard(padding: 12)
            }
        }
    }
    private func chooseRoot() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.directoryURL = URL(fileURLWithPath: root)
        if picker.runModal() == .OK, let chosen = picker.url { appState.analysisRoot = chosen.path; requestScan = true }
    }
}

struct OperationHistoryView: View {
    @State private var lines: [String] = []
    @Environment(\.workspaceSearch) private var search
    var body: some View {
        let filtered = lines.reversed().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                MolePageHeading(title: "History", detail: "Every scan, maintenance action and Trash move", symbol: "clock.arrow.circlepath")
                Spacer()
                Button("Refresh") { Task { lines = await OperationLog.shared.recentLines(limit: 500) } }
            }
            if filtered.isEmpty {
                TeboEmptyState(systemImage: "clock.arrow.circlepath", title: "No matching activity", message: "Your actions appear here as you use Tebo.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: line.contains("Trashed") ? "trash" : line.contains("Optimize") ? "slider.horizontal.3" : "magnifyingglass")
                                Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.teboCard()
                        }
                    }
                }
            }
        }.padding(24).task { lines = await OperationLog.shared.recentLines(limit: 500) }
    }
}
