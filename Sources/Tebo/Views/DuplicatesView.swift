import AppKit
import SwiftUI

// MARK: - DuplicatesView (czkawka: duplicates + similar media)
// Runs the bundled engine on a folder the user picks, streams findings, and shows them as a list,
// as thumbnails side by side, or as the closest pair per group. The engine is invoked read-only:
// it never sees a delete flag from us.

struct DuplicatesView: View {
    @Environment(AppState.self) private var appState

    @State private var tool: CzkawkaTool = .duplicates
    /// Where the engine looks. Home by default: these tools are slow on huge trees, so the user
    /// narrows it deliberately rather than us scanning everything.
    @State private var root: String = NSHomeDirectory()
    @State private var layout: DuplicateLayout = .list
    /// The engine's own strictness for similar images (`-s`, max difference). 5 is its default.
    @State private var imageMaxDifference = 5
    /// What the rows on screen were produced with, so the UI can say when a re-scan is due.
    @State private var scannedMaxDifference: Int?
    /// Raised when a setting changed and the shared scan path should run again.
    @State private var requestScan = false

    private static let offeredTools: [CzkawkaTool] = [
        .duplicates, .similarImages, .similarMusic, .similarVideos,
        .emptyFolders, .emptyFiles, .temporaryFiles, .bigFiles,
    ]

    /// Layouts only make sense where the engine reports groups of files.
    private static let groupedTools: Set<CzkawkaTool> = [
        .duplicates, .similarImages, .similarVideos, .similarMusic,
    ]

    var body: some View {
        let engine = appState.engine
        ScanTab(
            tabID: "duplicates",
            title: "Duplicates",
            subtitle: "Exact duplicates by hash, plus similar images, music and video",
            icon: "photo.on.rectangle.angled",
            recommendedExplanation: Self.groupedTools.contains(tool)
                ? "Ticks every copy in a group except the largest one, which stays."
                : nil,
            rowsOverride: { rows in
                AnyView(DuplicateRowsView(layout: layout, tool: tool, rows: rows))
            },
            rescanRequested: $requestScan,
            runScan: { await runScan(engine: engine) },
            extraInfo: {
                VStack(alignment: .leading, spacing: 10) {
                    if !engine.isReady {
                        HStack(spacing: 8) {
                            TeboBadge(text: "Engine missing", systemImage: "exclamationmark.triangle", tint: .orange)
                            Text(engine.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    controls
                    if tool == .similarImages {
                        similarityThreshold
                    }
                }
            }
        )
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Tool", selection: $tool) {
                ForEach(Self.offeredTools, id: \.self) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)

            if Self.groupedTools.contains(tool) {
                Picker("Layout", selection: $layout) {
                    ForEach(DuplicateLayout.allCases) { candidate in
                        Label(candidate.title, systemImage: candidate.symbol).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                .help(layout.help)
            }

            Spacer(minLength: 8)

            Button("Choose folder…") { chooseRoot() }
            TeboPath(path: root)
                .frame(maxWidth: 260)
        }
    }

    /// The engine measures similarity as a difference score: lower is stricter. Exposing it means
    /// the user decides how close "similar" has to be, instead of us picking a number for them.
    private var similarityThreshold: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("How similar counts as similar")
                    .font(.callout.weight(.medium))
                TeboBadge(
                    text: "difference ≤ \(imageMaxDifference)",
                    systemImage: "dial.medium",
                    tint: .accentColor
                )
                Spacer()
                if scannedMaxDifference != imageMaxDifference {
                    Button("Scan again to apply") { requestScan = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Slider(
                value: Binding(
                    get: { Double(imageMaxDifference) },
                    set: { imageMaxDifference = Int($0.rounded()) }
                ),
                in: 0...40,
                step: 1
            )

            HStack {
                Text("0 = pixel-identical").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("40 = loosely similar").font(.caption2).foregroundStyle(.tertiary)
            }

            Text("This is the engine's own measure. Its default is 5 and it recommends up to 10 for the hash size it uses here. Lower finds fewer, closer matches.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .teboCard(padding: 12)
    }

    // MARK: Scan

    private func runScan(engine: EngineStatus) async -> [ScanResult] {
        guard case .ready(let engineURL, _, _) = engine else {
            appState.setScanNote("Engine not available: nothing was scanned.", for: "duplicates")
            return []
        }
        let bridge = CzkawkaBridge(engineURL: engineURL)
        let directory = URL(fileURLWithPath: root)
        let threshold = tool == .similarImages ? imageMaxDifference : nil
        var rows: [ScanResult] = []
        var groups: [UUID: String] = [:]
        var details: [UUID: CzkawkaItemDetail] = [:]
        var failure: String?

        do {
            for try await item in bridge.scan(
                tool: tool,
                in: [directory],
                imageMaxDifference: threshold
            ) {
                if let groupID = item.groupID { groups[item.id] = groupID }
                if let detail = item.detail { details[item.id] = detail }
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

        scannedMaxDifference = threshold
        appState.groupByRowID = groups
        appState.mediaDetailByRowID = details

        // "Recommended" is decided here, where the groups are known: every copy except the
        // largest of its group, so a whole album collapses to one file per set.
        let keepers = SelectionPlan.keepersByGroup(rows: rows, groups: groups)
        rows = rows.map { row in
            ScanResult(
                id: row.id,
                path: row.path,
                sizeBytes: row.sizeBytes,
                category: row.category,
                reason: row.reason,
                recommendedForSelection: groups[row.id] != nil && !keepers.contains(row.id)
            )
        }

        if let failure {
            appState.setScanNote(failure, for: "duplicates")
        } else {
            let groupCount = Set(groups.values).count
            appState.setScanNote(
                groupCount > 0
                    ? "\(rows.count) items in \(groupCount) groups across \(TeboPath.abbreviate(root))"
                    : "\(rows.count) items across \(TeboPath.abbreviate(root))",
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
}
