import AppKit
import SwiftUI

// MARK: - DuplicatesView (czkawka: duplicates + similar media)
// Runs the bundled engine on a folder the user picks, streams findings, and lets the user select
// rows for the Trash. The engine is invoked read-only: it never sees a delete flag from us.

struct DuplicatesView: View {
    @Environment(AppState.self) private var appState

    @State private var tool: CzkawkaTool = .duplicates
    /// Where the engine looks. Home by default: the tools are slow on huge trees, so the user
    /// narrows it deliberately rather than us scanning everything.
    @State private var root: String = NSHomeDirectory()
    /// Group id per row, kept while mapping engine output, so "keep one per group" knows the groups.
    @State private var groupByRowID: [UUID: String] = [:]

    private static let offeredTools: [CzkawkaTool] = [
        .duplicates, .similarImages, .similarMusic, .similarVideos,
        .emptyFolders, .emptyFiles, .temporaryFiles, .bigFiles,
    ]

    var body: some View {
        let engine = appState.engine
        ScanTab(
            tabID: "duplicates",
            title: "Duplicates",
            subtitle: "Exact duplicates by hash, plus similar images, music and video",
            icon: "doc.on.doc",
            runScan: { await runScan(engine: engine) },
            extraInfo: {
                VStack(alignment: .leading, spacing: 8) {
                    if !engine.isReady {
                        Label(
                            "The bundled czkawka engine is not available, so this tab cannot scan. \(engine.summary)",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                    HStack {
                        Picker("Tool", selection: $tool) {
                            ForEach(Self.offeredTools, id: \.self) { tool in
                                Text(tool.displayName).tag(tool)
                            }
                        }
                        .frame(maxWidth: 260)
                        Spacer()
                        Button("Choose folder…") { chooseRoot() }
                        Text(root)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if tool == .duplicates && !groupByRowID.isEmpty {
                        Button("Keep one copy per group") { keepOnePerGroup() }
                            .buttonStyle(.bordered)
                            .help("Ticks every duplicate except one per group. Review before deleting.")
                    }
                }
            }
        )
    }

    // MARK: Scan

    private func runScan(engine: EngineStatus) async -> [ScanResult] {
        guard case .ready(let engineURL, _, _) = engine else {
            appState.setScanNote("Engine not available — nothing was scanned.", for: "duplicates")
            return []
        }
        let bridge = CzkawkaBridge(engineURL: engineURL)
        let directory = URL(fileURLWithPath: root)
        var rows: [ScanResult] = []
        var groups: [UUID: String] = [:]
        var failure: String?

        do {
            for try await item in bridge.scan(tool: tool, in: [directory]) {
                if let groupID = item.groupID { groups[item.id] = groupID }
                rows.append(ScanResult(
                    id: item.id,
                    path: item.path,
                    sizeBytes: item.sizeBytes,
                    category: item.category,
                    reason: item.reason
                ))
            }
        } catch {
            // A failed scan must never look like an empty folder.
            failure = "\(tool.displayName) scan failed: \(error.localizedDescription)"
        }

        groupByRowID = groups
        if let failure {
            appState.setScanNote(failure, for: "duplicates")
        } else {
            let groupCount = Set(groups.values).count
            appState.setScanNote(
                groupCount > 0
                    ? "\(rows.count) items in \(groupCount) groups across \(root)"
                    : "\(rows.count) items across \(root)",
                for: "duplicates"
            )
        }
        return rows
    }

    // MARK: Actions

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.prompt = "Scan here"
        if panel.runModal() == .OK, let picked = panel.url { root = picked.path }
    }

    /// Tick every row except one per group. Deliberately does not guess which copy is "better":
    /// the engine's output carries no modification time, so claiming to keep the newest would be
    /// a lie. It keeps the first row of each group and ticks the rest for the user to review.
    private func keepOnePerGroup() {
        var seenGroups: Set<String> = []
        var keep: Set<UUID> = []
        for row in appState.results(for: "duplicates") {
            guard let group = groupByRowID[row.id] else { continue }
            if seenGroups.insert(group).inserted {
                keep.insert(row.id)
            }
        }
        appState.selectedIDs = Set(appState.results(for: "duplicates").map(\.id)).subtracting(keep)
    }
}
