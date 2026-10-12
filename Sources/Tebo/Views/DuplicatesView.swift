import AppKit
import SwiftUI

/// Native Krokiet scan workflows, using the same bundled core as its upstream frontend.
struct DuplicatesView: View {
    @Environment(AppState.self) private var appState
    @Environment(WorkspaceActivity.self) private var activity
    @State private var tool: CzkawkaTool
    @State private var settings = MediaSettingsStore.load()
    @State private var layout: DuplicateLayout = .list
    let offeredTools: [CzkawkaTool]

    init(initialTool: CzkawkaTool = .duplicates, tools: [CzkawkaTool]? = nil) {
        _tool = State(initialValue: initialTool); offeredTools = tools ?? [initialTool]
    }
    var body: some View {
        let selectedTool = tool, configuration = settings, engine = appState.engine, whitelist = appState.whitelist
        let snapshots = Dictionary(appState.results(for: tool.tabID).compactMap { row in
            activity.mediaSnapshotsByTab[tool.tabID]?[row.id].map { (row.path, $0) }
        }, uniquingKeysWith: { a, _ in a })
        let referenceGuards = Dictionary(appState.results(for: tool.tabID).compactMap { row in
            activity.mediaReferenceGuardsByTab[tool.tabID]?[row.id].map { (row.path, $0) }
        }, uniquingKeysWith: { a, _ in a })
        ScanTab(tabID: tool.tabID, title: tool.displayName, subtitle: subtitle, icon: tool.symbol,
                scanScope: settings.scope,
                recommendedExplanation: tool.isGrouped ? "Review every group. Suggestions keep the largest copy, or keep reference-folder originals. Name and size matches have no default selection." : nil,
                rowsOverride: { AnyView(DuplicateRowsView(layout: tool.isGrouped ? layout : .list, tool: tool, rows: $0)) },
                removalValidator: { path in MediaScanService.removalReason(path: path, tool: selectedTool, settings: configuration, expected: snapshots[path], referenceGuard: referenceGuards[path]) },
                runScan: {
                    guard case .ready(let engineURL, _, _) = engine else {
                        appState.setScanNote("Engine unavailable: " + engine.summary, for: selectedTool.tabID); return []
                    }
                    if selectedTool == .similarVideos, appState.ffmpegPath == nil {
                        appState.setScanNote("Similar video scanning requires ffmpeg. Nothing was scanned.", for: selectedTool.tabID); return []
                    }
                    do {
                        let report = try await MediaScanService(engineURL: engineURL).scan(tool: selectedTool, settings: configuration, whitelist: whitelist)
                        try Task.checkCancellation()
                        appState.groupByRowID = report.groups; appState.mediaDetailByRowID = report.details
                        activity.groupsByTab[selectedTool.tabID] = report.groups; activity.detailsByTab[selectedTool.tabID] = report.details
                        activity.mediaSnapshotsByTab[selectedTool.tabID] = report.snapshots
                        activity.mediaReferenceGuardsByTab[selectedTool.tabID] = report.referenceGuards
                        appState.advisoriesByTab[selectedTool.tabID] = report.kept
                        let groups = Set(report.groups.values).count
                        appState.setScanNote("\(report.rows.count) selectable items\(groups > 0 ? " in \(groups) groups" : ""). Reference and protected entries stay kept.", for: selectedTool.tabID)
                        return report.rows
                    } catch {
                        guard !Task.isCancelled else { return [] }
                        appState.setScanNote("Scan failed: " + error.localizedDescription, for: selectedTool.tabID); return []
                    }
                }, extraInfo: {
                    VStack(alignment: .leading, spacing: 12) {
                        if !engine.isReady { Text(engine.summary).font(.caption).foregroundStyle(.secondary) }
                        if offeredTools.count > 1 {
                            Picker("File check", selection: $tool) { ForEach(offeredTools, id: \.self) { Text($0.displayName).tag($0) } }
                        }
                        if tool.isGrouped {
                            Picker("Result layout", selection: $layout) {
                                ForEach(DuplicateLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden()
                        }
                        MediaScanControls(settings: $settings, tool: tool)
                        ReviewPanel(note: appState.scanNote(for: tool.tabID), advisories: appState.advisories(for: tool.tabID))
                    }.disabled(activity.isScanning)
                })
        .id(tool)
        .onAppear { restoreDetails() }
        .onChange(of: tool) { _, _ in appState.clearSelection(); restoreDetails() }
        .onChange(of: settings) { _, value in MediaSettingsStore.save(value) }
    }
    private var subtitle: String {
        switch tool {
        case .duplicates: "Compare files by content, size or name"
        case .similarImages: "Compare perceptual hashes and review images side by side"
        case .similarVideos: "Compare video frames or audio fingerprints"
        case .similarMusic: "Compare audio fingerprints or music tags"
        default: "Inspect the folders you choose, then review each finding"
        }
    }
    private func restoreDetails() {
        appState.groupByRowID = activity.groupsByTab[tool.tabID] ?? [:]
        appState.mediaDetailByRowID = activity.detailsByTab[tool.tabID] ?? [:]
    }
}
