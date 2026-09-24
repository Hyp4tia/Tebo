import SwiftUI

// MARK: - ScanTab (reusable logic for Clean / Duplicates / Disk / Toolbox)
// Each tab is: title + Scan button + stat + checkbox list + Delete button.
// This base view holds ALL that logic so the 6 tabs stay tiny.

/// Generic scan tab. Pass tabID + how to scan, get full UI for free.
/// Example: `ScanTab(tabID: "clean", title: "Smart Clean", runScan: myFunc)`
struct ScanTab<ExtraInfo: View>: View {
    // Which bucket in AppState.resultsByTab to use (e.g. "clean").
    let tabID: String
    let title: String
    let subtitle: String
    let icon: String

    // Async scan closure provided by each tab (mock now, engine later).
    let runScan: () async -> [ScanResult]

    // Optional extra UI under the header (e.g. ffmpeg warning).
    @ViewBuilder let extraInfo: () -> ExtraInfo

    @Environment(AppState.self) private var appState
    @State private var isScanning = false
    @State private var showConfirm = false

    init(
        tabID: String, title: String, subtitle: String, icon: String,
        runScan: @escaping () async -> [ScanResult],
        @ViewBuilder extraInfo: @escaping () -> ExtraInfo = { EmptyView() }
    ) {
        self.tabID = tabID
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.runScan = runScan
        self.extraInfo = extraInfo
    }

    var body: some View {
        // Read state once per render (cheap, no disk access here).
        let items = appState.results(for: tabID)
        let selectedBytes = appState.selectedBytes(for: tabID)
        let totalBytes = items.reduce(0) { $0 + $1.sizeBytes }

        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text(title).font(.largeTitle).bold()
                    Text(subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                ScanButton(title: "Scan", isScanning: isScanning) { startScan() }
            }

            extraInfo()

            // Stats
            HStack {
                StatCard(title: "Found", value: "\(items.count) items", systemImage: icon)
                StatCard(
                    title: "Reclaimable",
                    value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file),
                    systemImage: "externaldrive.badge.timemachine"
                )
                StatCard(
                    title: "Selected",
                    value: ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file),
                    systemImage: "checkmark.circle"
                )
            }

            // Empty state — centered in the leftover space.
            // VStack is .leading, so we force full width+height + center.
            if items.isEmpty && !isScanning {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: icon,
                    description: Text("Press Scan to preview. Dry-run is on — nothing will be deleted.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(items) { item in
                            PreviewRow(
                                item: item,
                                isSelected: appState.selectedIDs.contains(item.id)
                            ) { toggle(item) }
                            Divider()
                        }
                    }
                }
            }

            Spacer()

            // Delete bar (disabled unless something selected)
            HStack {
                Text(appState.dryRunEnabled ? "Dry-run ON — preview only" : "Dry-run OFF — will move to Trash")
                    .font(.caption)
                    .foregroundStyle(appState.dryRunEnabled ? .green : .orange)
                Spacer()
                Button("Move Selected to Trash") { showConfirm = true }
                    .buttonStyle(.bordered)
                    .disabled(appState.selectedResults(for: tabID).isEmpty)
            }
        }
        .padding()
        .confirmationDialog(
            "Move \(appState.selectedResults(for: tabID).count) items to Trash?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)). Reversible from Trash.")
        }
    }

    // MARK: Actions (small, named clearly)

    private func startScan() {
        isScanning = true
        appState.clearSelection()
        Task {
            let found = await runScan()
            // Filter through SafetyGate BEFORE showing (fail closed).
            let safe = SafetyGate.filterAllowed(found, whitelist: appState.whitelist)
            appState.resultsByTab[tabID] = safe
            await OperationLog.shared.record("[\(tabID)] Previewed \(safe.count) items")
            isScanning = false
        }
    }

    private func toggle(_ item: ScanResult) {
        if appState.selectedIDs.contains(item.id) {
            appState.selectedIDs.remove(item.id)
        } else {
            appState.selectedIDs.insert(item.id)
        }
    }

    private func trashSelected() {
        // M1: dry-run or real Trash via CleanerService.
        let paths = appState.selectedResults(for: tabID).map(\.path)
        Task {
            if appState.dryRunEnabled {
                await OperationLog.shared.record("[\(tabID)] Dry-run: would trash \(paths.count) items")
            } else {
                await CleanerService().moveToTrash(paths: paths, whitelist: appState.whitelist)
                // Refresh list after delete.
                appState.resultsByTab[tabID] = appState.results(for: tabID)
                    .filter { !paths.contains($0.path) }
                appState.clearSelection()
            }
        }
    }
}
