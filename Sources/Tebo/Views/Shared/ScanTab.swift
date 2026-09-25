import SwiftUI

// MARK: - ScanTab
// The results surface every tab shares: header, live totals, per-tab controls, selection
// commands, grouped rows, and one action bar. Tabs stay small by owning only their scan.

struct ScanTab<ExtraInfo: View>: View {
    /// Which bucket in `AppState.resultsByTab` to use (e.g. "clean").
    let tabID: String
    let title: String
    let subtitle: String
    let icon: String

    /// Runs the tab's own scan and returns the rows it found.
    let runScan: () async -> [ScanResult]

    /// What "Select recommended" means in this tab, shown beside the button. nil when the tool has
    /// no safe default (then the button stays disabled instead of guessing).
    let recommendedExplanation: String?

    /// Optional override for how result rows are laid out (the Duplicates tab offers image grid
    /// and compare views). nil renders the default grouped sections.
    let rowsOverride: (([ScanResult]) -> AnyView)?

    /// Set to true by a tab that changed a scan setting and wants the scan to run again through
    /// the shared path (one owner for the scanning state, not two).
    var rescanRequested: Binding<Bool>?

    /// Per-tab controls (tool picker, folder chooser, sliders, review panel).
    @ViewBuilder let extraInfo: () -> ExtraInfo

    @Environment(AppState.self) private var appState
    @State private var isScanning = false
    @State private var showConfirm = false
    @State private var scanTask: Task<Void, Never>?
    /// Bumped after each scan so row previews are re-read from disk.
    @State private var refreshToken = 0

    init(
        tabID: String,
        title: String,
        subtitle: String,
        icon: String,
        recommendedExplanation: String? = nil,
        rowsOverride: (([ScanResult]) -> AnyView)? = nil,
        rescanRequested: Binding<Bool>? = nil,
        runScan: @escaping () async -> [ScanResult],
        @ViewBuilder extraInfo: @escaping () -> ExtraInfo = { EmptyView() }
    ) {
        self.tabID = tabID
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.recommendedExplanation = recommendedExplanation
        self.rowsOverride = rowsOverride
        self.rescanRequested = rescanRequested
        self.runScan = runScan
        self.extraInfo = extraInfo
    }

    var body: some View {
        let items = appState.results(for: tabID)
        let selectedBytes = appState.selectedBytes(for: tabID)
        let totalBytes = items.reduce(0) { $0 + $1.sizeBytes }
        let selectedCount = appState.selectedResults(for: tabID).count
        let recommendedCount = items.filter(\.recommendedForSelection).count

        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    totals(items: items, totalBytes: totalBytes, selectedBytes: selectedBytes)
                    extraInfo()
                    selectionBar(items: items, recommendedCount: recommendedCount)

                    if isScanning {
                        scanningIndicator
                    } else if items.isEmpty {
                        TeboEmptyState(
                            systemImage: icon,
                            title: appState.scanNote(for: tabID) == nil ? "Nothing scanned yet" : "Nothing found",
                            message: appState.scanNote(for: tabID)
                                ?? "Scan to see what this tab can free. Preview is on, so nothing is deleted.",
                            actionTitle: "Scan now",
                            action: { startScan() }
                        )
                        .frame(minHeight: 260)
                    } else if let rowsOverride {
                        rowsOverride(items)
                    } else {
                        ForEach(sections(items)) { section in
                            ResultSection(
                                category: section.category,
                                rows: section.rows,
                                isSelected: { appState.selectedIDs.contains($0.id) },
                                refreshToken: refreshToken,
                                onToggle: { toggle($0) },
                                onSelectCategory: { selectAll in
                                    selectAll
                                        ? appState.select(section.rows.map(\.id))
                                        : appState.deselect(section.rows.map(\.id))
                                }
                            )
                        }
                    }
                }
                .padding(16)
            }

            actionBar(selectedCount: selectedCount, selectedBytes: selectedBytes, hasRows: !items.isEmpty)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: rescanRequested?.wrappedValue) { _, requested in
            guard requested == true else { return }
            rescanRequested?.wrappedValue = false
            startScan()
        }
        .confirmationDialog(
            appState.dryRunEnabled
                ? "Preview only"
                : "Move \(selectedCount) items to the Trash?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            if !appState.dryRunEnabled {
                Button("Move to Trash", role: .destructive) { trashSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(appState.dryRunEnabled
                 ? "Preview is on, so nothing was moved. Turn Preview off in the top bar to delete."
                 : "Frees \(TeboBytes.text(selectedBytes)). Reversible from the Trash.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if isScanning {
                Button("Cancel") { scanTask?.cancel() }
                    .buttonStyle(.bordered)
            }
            ScanButton(title: "Scan", isScanning: isScanning) { startScan() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Totals

    private func totals(items: [ScanResult], totalBytes: Int64, selectedBytes: Int64) -> some View {
        HStack(spacing: 12) {
            StatTile(
                label: "Found",
                value: "\(items.count)",
                unit: items.count == 1 ? "item" : "items",
                systemImage: icon
            )
            StatTile(
                label: "Reclaimable",
                value: TeboBytes.text(totalBytes),
                systemImage: "externaldrive.badge.minus",
                tint: .accentColor,
                detail: "if everything listed goes"
            )
            StatTile(
                label: "Selected",
                value: TeboBytes.text(selectedBytes),
                systemImage: "checkmark.circle",
                detail: appState.selectedResults(for: tabID).isEmpty ? "nothing ticked yet" : "ready to move"
            )
        }
    }

    // MARK: Selection

    private func selectionBar(items: [ScanResult], recommendedCount: Int) -> some View {
        HStack(spacing: 8) {
            Button("Select all") { appState.selectAll(for: tabID) }
                .disabled(items.isEmpty)

            Button("Select recommended (\(recommendedCount))") { appState.selectRecommended(for: tabID) }
                .disabled(recommendedCount == 0)
                .help(recommendedExplanation
                      ?? "This tool has no safe default: every row here needs a look before it goes.")

            Button("Clear") { appState.clearSelection() }
                .disabled(appState.selectedResults(for: tabID).isEmpty)

            Spacer()

            if let recommendedExplanation {
                Text(recommendedExplanation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .trailing)
            }
        }
    }

    private var scanningIndicator: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Scanning. Rows appear as the engine finds them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 24)
    }

    // MARK: Action bar

    private func actionBar(selectedCount: Int, selectedBytes: Int64, hasRows: Bool) -> some View {
        HStack(spacing: 12) {
            Label(
                appState.dryRunEnabled ? "Preview is on" : "Preview is off",
                systemImage: appState.dryRunEnabled ? "eye" : "trash"
            )
            .font(.caption)
            .foregroundStyle(appState.dryRunEnabled ? Color.secondary : Color.orange)

            Spacer()

            if selectedCount > 0 {
                Text("\(selectedCount) selected · \(TeboBytes.text(selectedBytes))")
                    .font(.callout)
                    .monospacedDigit()
            }

            Button(selectedCount > 0 ? "Move \(selectedCount) to Trash" : "Move to Trash") {
                showConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedCount == 0 || appState.dryRunEnabled)
            .help(appState.dryRunEnabled
                  ? "Preview is on: turn it off in the top bar to move files to the Trash."
                  : "Moves the ticked rows to the Trash. Reversible from the Trash.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }

    // MARK: Rows by source table

    private struct Section: Identifiable {
        let category: String
        let rows: [ScanResult]
        let bytes: Int64
        var id: String { category }
    }

    /// Rows grouped by the table they came from, biggest group first, like the cleaner's own
    /// sections. Falls back to a single section when the tool produces one category.
    private func sections(_ rows: [ScanResult]) -> [Section] {
        Dictionary(grouping: rows, by: \.category)
            .map { category, rows in
                Section(
                    category: category,
                    rows: rows.sorted { $0.sizeBytes > $1.sizeBytes },
                    bytes: rows.reduce(0) { $0 + $1.sizeBytes }
                )
            }
            .sorted { $0.bytes > $1.bytes }
    }

    // MARK: Actions

    private func startScan() {
        isScanning = true
        appState.clearSelection()
        scanTask = Task {
            let found = await runScan()
            guard !Task.isCancelled else {
                isScanning = false
                return
            }
            // Filter through SafetyGate BEFORE showing (fail closed).
            let safe = SafetyGate.filterAllowed(found, whitelist: appState.whitelist)
            appState.resultsByTab[tabID] = safe
            await OperationLog.shared.record("[\\(tabID)] Previewed \\(safe.count) items")
            refreshToken += 1
            isScanning = false
        }
    }

    private func toggle(_ item: ScanResult) {
        appState.toggleSelection(item.id)
    }

    private func trashSelected() {
        let paths = appState.selectedResults(for: tabID).map(\.path)
        Task {
            if appState.dryRunEnabled {
                await OperationLog.shared.record("[\\(tabID)] Dry-run: would trash \\(paths.count) items")
            } else {
                await CleanerService().moveToTrash(paths: paths, whitelist: appState.whitelist)
                appState.resultsByTab[tabID] = appState.results(for: tabID)
                    .filter { !paths.contains($0.path) }
                appState.clearSelection()
            }
        }
    }
}
