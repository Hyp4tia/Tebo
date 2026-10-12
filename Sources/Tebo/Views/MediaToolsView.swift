import AppKit
import SwiftUI

struct MediaToolsView: View {
    @Environment(AppState.self) private var appState
    @Environment(WorkspaceActivity.self) private var activity
    @Environment(\.workspaceSearch) private var search
    @State private var tool: CzkawkaTool = MediaSettingsStore.exportTool()
    @State private var settings = MediaSettingsStore.load()
    @State private var items: [CzkawkaItem] = []
    @State private var snapshots: [UUID: MediaFileSnapshot] = [:]
    @State private var kept: [AdvisoryRow] = []
    @State private var selected: Set<UUID> = []
    @State private var outputFolder: URL?
    @State private var outputOptions = MediaExportOptions()
    @State private var message: String?
    @State private var busy: String?
    @State private var operation: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var confirmExport = false
    private let tools: [CzkawkaTool] = [.exifMetadata, .videoTranscode, .videoCrop]
    private var visible: [CzkawkaItem] { items.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) || $0.reason.localizedCaseInsensitiveContains(search) } }
    private var chosen: [CzkawkaItem] { items.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MolePageHeading(title: "Media Tools", detail: "Clean metadata, transcode videos and crop borders", symbol: "wand.and.stars")
                Spacer()
                if busy != nil { Button("Cancel") { cancel() } }
                Button(busy == "scan" ? "Scanning…" : "Scan") { scan() }.buttonStyle(TeboPrimaryButtonStyle()).disabled(busy != nil)
            }.padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Media tool", selection: $tool) { ForEach(tools, id: \.self) { Text($0.displayName).tag($0) } }
                    HStack(spacing: 12) {
                        StatTile(label: "Found", value: String(visible.count), unit: "files", systemImage: tool.symbol)
                        StatTile(label: "Source size", value: TeboBytes.text(visible.reduce(0) { $0 + $1.sizeBytes }), systemImage: "externaldrive")
                        StatTile(label: "Selected", value: String(selected.count), unit: "files", systemImage: "checkmark.circle")
                    }
                    MediaScanControls(settings: $settings, tool: tool).disabled(busy != nil)
                    exportControls.disabled(busy != nil)
                    ReviewPanel(note: message, advisories: kept)
                    HStack {
                        Button("Select visible") { selected.formUnion(visible.map(\.id)) }.disabled(visible.isEmpty)
                        Button("Clear") { selected.removeAll() }.disabled(selected.isEmpty)
                        Spacer()
                        Toggle("Preview", isOn: Binding(get: { appState.dryRunEnabled }, set: { appState.dryRunEnabled = $0 })).toggleStyle(.switch).controlSize(.small)
                    }.disabled(busy != nil)
                    if busy == "scan" { ProgressView("Reading media…").padding(20) }
                    else if items.isEmpty { TeboEmptyState(systemImage: tool.symbol, title: "No media listed", message: "Choose folders and scan. Files are measured by the bundled engine.") }
                    else {
                        ResultSection(category: tool.displayName, rows: visible.map { ScanResult(id: $0.id, path: $0.path, sizeBytes: $0.sizeBytes, category: $0.category, reason: $0.reason) },
                                      isSelected: { selected.contains($0.id) }, refreshToken: 0,
                                      onToggle: { row in if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) } },
                                      onSelectCategory: { all in if all { selected.formUnion(visible.map(\.id)) } else { selected.subtract(visible.map(\.id)) } })
                        .disabled(busy != nil)
                    }
                }.padding(16)
            }
            HStack {
                Text("Originals are retained.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(appState.dryRunEnabled ? "Preview export" : "Export copies") {
                    if appState.dryRunEnabled { export() } else { confirmExport = true }
                }.buttonStyle(TeboPrimaryButtonStyle())
                    .disabled(chosen.isEmpty || busy != nil || (!appState.dryRunEnabled && outputFolder == nil))
            }.padding(16)
        }
        .onAppear { restore() }
        .onChange(of: tool) { _, value in MediaSettingsStore.saveExportTool(value); cancel(); restore() }
        .onChange(of: settings) { _, value in MediaSettingsStore.save(value); invalidate() }
        .onDisappear { cancel() }
        .confirmationDialog("Export \(chosen.count) new copies?", isPresented: $confirmExport, titleVisibility: .visible) {
            Button("Export copies") { export() }; Button("Cancel", role: .cancel) {}
        } message: { Text("Source files remain unchanged. Copies are saved into the chosen output folder.") }
    }
    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Save new copies").font(.callout.weight(.medium)); Spacer()
                Button("Output folder…") { chooseOutput() }
            }
            Text(outputFolder.map { TeboPath.abbreviate($0.path) } ?? "Choose a folder before exporting.").font(.caption).foregroundStyle(.secondary)
            if tool != .exifMetadata {
                DisclosureGroup("Output settings") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Codec", selection: $outputOptions.codec) {
                            Text("H.264").tag("h264"); Text("HEVC").tag("h265"); Text("AV1").tag("av1"); Text("VP9").tag("vp9")
                        }
                        Stepper("Quality: \(outputOptions.quality), lower keeps more detail", value: $outputOptions.quality, in: 0...51)
                        Toggle("Limit output dimensions", isOn: $outputOptions.limitSize)
                        if outputOptions.limitSize {
                            TextField("Maximum width", value: $outputOptions.maxWidth, format: .number)
                            TextField("Maximum height", value: $outputOptions.maxHeight, format: .number)
                        }
                        Toggle("Save only if smaller", isOn: $outputOptions.requireSmaller)
                    }.padding(.top, 8).textFieldStyle(.roundedBorder)
                }
                Text("Creates an 8-bit video copy with audio. Subtitle and data tracks are omitted.").font(.caption).foregroundStyle(.secondary)
                if appState.ffmpegPath == nil { Text("Video scans and exports require ffmpeg.").font(.caption).foregroundStyle(.orange) }
            } else {
                Text("Metadata is removed from a new copy. Essential orientation and specified tag names are retained.").font(.caption).foregroundStyle(.secondary)
            }
        }.teboCard(padding: 12)
    }
    private func chooseOutput() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Save copies here"
        if panel.runModal() == .OK { outputFolder = panel.url }
    }
    private func invalidate() {
        cancel(); items = []; snapshots = [:]; selected = []; kept = []; message = nil
        appState.updateScanScope(settings.scope, for: tool.tabID)
        activity.mediaSnapshotsByTab.removeValue(forKey: tool.tabID)
        activity.detailsByTab.removeValue(forKey: tool.tabID)
    }
    private func restore() {
        selected = []
        appState.updateScanScope(settings.scope, for: tool.tabID)
        let details = activity.detailsByTab[tool.tabID] ?? [:]
        items = appState.results(for: tool.tabID).map { CzkawkaItem(id: $0.id, path: $0.path, sizeBytes: $0.sizeBytes, tool: tool, detail: details[$0.id]) }
        snapshots = activity.mediaSnapshotsByTab[tool.tabID] ?? [:]
        kept = appState.advisories(for: tool.tabID); message = appState.scanNote(for: tool.tabID)
    }
    private func cancel() {
        if busy == "export" { message = "Cancelled. Completed copies remain in the output folder." }
        operation?.cancel(); requestID = UUID(); busy = nil; activity.isScanning = false
    }
    private func scan() {
        guard case .ready(let url, _, _) = appState.engine else { message = appState.engine.summary; return }
        guard tool == .exifMetadata || appState.ffmpegPath != nil else { message = "ffmpeg is unavailable. Nothing was scanned."; return }
        let selectedTool = tool, configuration = settings, whitelist = appState.whitelist, started = Date.now
        let token = UUID(); requestID = token; busy = "scan"; activity.isScanning = true; selected = []
        operation = Task {
            do {
                let report = try await MediaScanService(engineURL: url).scan(tool: selectedTool, settings: configuration, whitelist: whitelist)
                let found = report.rows.map { CzkawkaItem(id: $0.id, path: $0.path, sizeBytes: $0.sizeBytes, tool: selectedTool, detail: report.details[$0.id]) }
                let identities = report.snapshots
                guard !Task.isCancelled, requestID == token else { return }
                appState.updateScanScope(configuration.scope, for: selectedTool.tabID)
                appState.resultsByTab[selectedTool.tabID] = report.rows
                appState.advisoriesByTab[selectedTool.tabID] = report.kept
                activity.detailsByTab[selectedTool.tabID] = report.details
                activity.mediaSnapshotsByTab[selectedTool.tabID] = identities
                items = found; snapshots = identities; kept = report.kept; message = "\(found.count) files reviewed. Nothing changed."
                appState.setScanNote(message, for: selectedTool.tabID)
                await OperationLog.shared.record("[\(selectedTool.tabID)] Previewed \(found.count) media files")
                guard !Task.isCancelled, requestID == token else { return }
                busy = nil; activity.recordScan(started: started)
            } catch {
                guard requestID == token else { return }; busy = nil; activity.isScanning = false
                if !Task.isCancelled { message = "Scan failed: " + error.localizedDescription }
            }
        }
    }
    private func export() {
        let files = chosen, selectedTool = tool, preview = appState.dryRunEnabled, folder = outputFolder ?? FileManager.default.temporaryDirectory
        var options = outputOptions
        options.ignoredExifTags = Set(settings.ignoredExifTags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let identities = snapshots, whitelist = appState.whitelist, references = settings.references, service = MediaExportService(ffmpegPath: appState.ffmpegPath)
        let token = UUID(); requestID = token; busy = "export"
        operation = Task {
            var outcomes: [String] = []
            for item in files {
                if Task.isCancelled { break }
                do {
                    guard let expected = identities[item.id] else { throw MediaExportError.refused("No source identity. Scan again.") }
                    let result = try await service.export(item: item, expected: expected, to: folder, options: options, preview: preview, whitelist: whitelist, references: references)
                    switch result {
                    case .preview: outcomes.append("Preview: " + item.displayName)
                    case .exported(let url):
                        outcomes.append("Saved: " + TeboPath.abbreviate(url.path))
                        await OperationLog.shared.record("[\(selectedTool.tabID)] Exported copy: " + url.path)
                    }
                } catch { outcomes.append(item.displayName + ": " + error.localizedDescription) }
            }
            guard requestID == token else { return }
            message = outcomes.joined(separator: "\n"); busy = nil
            appState.setScanNote(message, for: selectedTool.tabID)
            await OperationLog.shared.record("[\(selectedTool.tabID)] \(preview ? "Preview export" : "Export completed"): \(outcomes.count) reviewed items; originals retained")
        }
    }
}
