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
    let foundLabel: String
    let sizeLabel: String
    let emptyMessage: String?
    let scanScope: [String]?

    /// Runs the tab's own scan and returns the rows it found.
    let runScan: () async -> [ScanResult]
    let removalValidator: (@Sendable (String) async -> String?)?
    let moleRemovalValidator: (@Sendable (ScanResult, Set<String>) async -> String?)?
    let rendersEmptyRowsOverride: Bool

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
    @Environment(WorkspaceActivity.self) private var activity
    @Environment(\.workspaceSearch) private var search
    @State private var isScanning = false
    @State private var showConfirm = false
    @State private var scanTask: Task<Void, Never>?
    @State private var scanRequestID = UUID()
    @State private var removalTask: Task<Void, Never>?
    @State private var removalRequestID = UUID()
    @State private var isRemoving = false
    @State private var isCancellingRemoval = false
    @State private var pendingMoleReview: MoleRemovalReview?
    /// Bumped after each scan so row previews are re-read from disk.
    @State private var refreshToken = 0

    init(
        tabID: String,
        title: String,
        subtitle: String,
        icon: String,
        foundLabel: String = "Found",
        sizeLabel: String = "Reclaimable",
        emptyMessage: String? = nil,
        scanScope: [String]? = nil,
        recommendedExplanation: String? = nil,
        rowsOverride: (([ScanResult]) -> AnyView)? = nil,
        rescanRequested: Binding<Bool>? = nil,
        rendersEmptyRowsOverride: Bool = false,
        removalValidator: (@Sendable (String) async -> String?)? = nil,
        moleRemovalValidator: (@Sendable (ScanResult, Set<String>) async -> String?)? = nil,
        runScan: @escaping () async -> [ScanResult],
        @ViewBuilder extraInfo: @escaping () -> ExtraInfo = { EmptyView() }
    ) {
        self.tabID = tabID
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.foundLabel = foundLabel
        self.sizeLabel = sizeLabel
        self.emptyMessage = emptyMessage
        self.scanScope = scanScope
        self.recommendedExplanation = recommendedExplanation
        self.rowsOverride = rowsOverride
        self.rescanRequested = rescanRequested
        self.runScan = runScan
        self.removalValidator = removalValidator
        self.moleRemovalValidator = moleRemovalValidator
        self.rendersEmptyRowsOverride = rendersEmptyRowsOverride
        self.extraInfo = extraInfo
    }

    var body: some View {
        let items = appState.results(for: tabID).filter {
            search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)
                || $0.category.localizedCaseInsensitiveContains(search)
                || $0.reason.localizedCaseInsensitiveContains(search)
        }
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
                    } else if items.isEmpty, rendersEmptyRowsOverride, let rowsOverride,
                              appState.scanNote(for: tabID) != nil {
                        rowsOverride(items)
                    } else if items.isEmpty {
                        TeboEmptyState(
                            systemImage: icon,
                            title: appState.resultsByTab[tabID] == nil ? "Nothing scanned yet" : "Nothing found",
                            message: appState.scanNote(for: tabID)
                                ?? emptyMessage ?? "Scan to see what this tab can free. Scanning is read-only; review results before removal.",
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
        .background(TeboPalette.canvas)
        .onDisappear {
            cancelScan()
            cancelRemoval(showNote: false)
        }
        .onChange(of: scanScope, initial: true) { _, _ in synchronizeScope() }
        .onChange(of: appState.whitelist) { oldValue, newValue in
            guard AppState.isMoleTab(tabID), oldValue != newValue else { return }
            cancelRemoval(showNote: false)
            activity.identitiesByTab.removeValue(forKey: tabID)
            activity.bindingsByTab.removeValue(forKey: tabID)
        }
        .onChange(of: appState.protectionError) { _, error in
            guard AppState.isMoleTab(tabID), error != nil else { return }
            cancelRemoval(showNote: false)
        }
        .onChange(of: rescanRequested?.wrappedValue) { _, requested in
            guard requested == true else { return }
            rescanRequested?.wrappedValue = false
            startScan()
        }
        .confirmationDialog(
            appState.dryRunEnabled
                ? "Preview only"
                : "Move \(AppState.isMoleTab(tabID) ? (pendingMoleReview?.selectedIDs.count ?? 0) : selectedCount) items to the Trash?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            if !appState.dryRunEnabled {
                Button("Move to Trash", role: .destructive) {
                    if AppState.isMoleTab(tabID) { confirmMoleRemoval() }
                    else { trashSelected() }
                }
            }
            Button("Cancel", role: .cancel) {
                if AppState.isMoleTab(tabID) { cancelRemoval(showNote: false) }
            }
        } message: {
            Text(appState.dryRunEnabled
                 ? "Preview is on, so nothing was moved. Turn Preview off in Settings to delete."
                 : AppState.isMoleTab(tabID)
                    ? "Moves exactly the reviewed selection to the Trash. The displayed size is logical item size, not measured free-space gain. Moving to Trash does not immediately free disk storage; you can recover items from the Trash."
                    : "Moves the reviewed items to Trash. Reversible from the Trash.")
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
                Button("Cancel") { cancelScan() }
                    .buttonStyle(TeboButtonStyle())
            }
            ScanButton(title: "Scan", isScanning: isScanning) { startScan() }
                .disabled(AppState.isMoleTab(tabID) && isRemoving)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Totals

    private func totals(items: [ScanResult], totalBytes: Int64, selectedBytes: Int64) -> some View {
        let isMole = AppState.isMoleTab(tabID)
        let usesDefaultMoleSizeLabel = isMole && sizeLabel == "Reclaimable"
        return HStack(spacing: 12) {
            StatTile(
                label: foundLabel,
                value: "\(items.count)",
                unit: items.count == 1 ? "item" : "items",
                systemImage: icon
            )
            StatTile(
                label: usesDefaultMoleSizeLabel ? "Logical size" : sizeLabel,
                value: (items.contains { !$0.isSizeComplete } ? "≥ " : "") + TeboBytes.text(totalBytes),
                systemImage: "externaldrive.badge.minus",
                tint: .accentColor,
                detail: isMole ? "Estimated item size" : "if everything listed goes"
            )
            StatTile(
                label: "Selected",
                value: (appState.selectedResults(for: tabID).contains { !$0.isSizeComplete } ? "≥ " : "") + TeboBytes.text(selectedBytes),
                systemImage: "checkmark.circle",
                detail: appState.selectedResults(for: tabID).isEmpty ? "nothing ticked yet"
                    : AppState.isMoleTab(tabID) ? "logical size ready to move" : "ready to move"
            )
        }
    }

    // MARK: Selection

    private func selectionBar(items: [ScanResult], recommendedCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Button("Select all") { appState.select(items.map(\.id)) }
                .disabled(items.isEmpty)

            Button("Select recommended (\(recommendedCount))") {
                if AppState.isMoleTab(tabID) {
                    appState.selectRecommended(for: tabID, visibleIDs: Set(items.map(\.id)))
                } else {
                    appState.select(items.filter(\.recommendedForSelection).map(\.id))
                }
            }
                .disabled(recommendedCount == 0 && (!AppState.isMoleTab(tabID) || appState.selectedResults(for: tabID).isEmpty))
                .help(recommendedExplanation
                      ?? "This tool has no safe default: every row here needs a look before it goes.")

            Button("Clear") {
                if AppState.isMoleTab(tabID) {
                    appState.deselect(appState.results(for: tabID).map(\.id))
                } else {
                    appState.clearSelection()
                }
            }
                .disabled(appState.selectedResults(for: tabID).isEmpty)

            Spacer()
          }
            if let recommendedExplanation {
                Text(recommendedExplanation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var scanningIndicator: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Scanning files…")
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
                Text("\(selectedCount) selected · \(TeboBytes.text(selectedBytes))\(AppState.isMoleTab(tabID) ? " logical size" : "")")
                    .font(.callout)
                    .monospacedDigit()
            }

            if AppState.isMoleTab(tabID), isRemoving {
                Button(isCancellingRemoval ? "Cancelling…" : "Cancel move") { cancelRemoval(showNote: true) }
                    .buttonStyle(TeboButtonStyle())
                    .disabled(isCancellingRemoval)
            } else {
                Button(selectedCount > 0 ? "Move \(selectedCount) to Trash" : "Move to Trash") {
                    if AppState.isMoleTab(tabID) { beginMoleConfirmation() }
                    else { showConfirm = true }
                }
                .buttonStyle(TeboPrimaryButtonStyle())
                .disabled(selectedCount == 0 || appState.dryRunEnabled
                          || (AppState.isMoleTab(tabID) && appState.protectionError != nil))
                .help(appState.dryRunEnabled
                      ? "Preview is on: turn it off in Settings to move files to the Trash."
                      : AppState.isMoleTab(tabID)
                        ? "Confirms the exact reviewed selection. Items move to the Trash, and the size is not measured free-space gain."
                        : "Moves the ticked rows to the Trash. Reversible from the Trash.")
            }
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

    private func cancelScan() {
        scanTask?.cancel()
        scanRequestID = UUID()
        isScanning = false
        activity.isScanning = false
    }

    private func synchronizeScope() {
        let changed: Bool
        if AppState.isMoleTab(tabID) {
            changed = appState.updateScanScope(scanScope ?? [], for: tabID)
        } else if let scanScope {
            changed = appState.updateScanScope(scanScope, for: tabID)
        } else {
            changed = false
        }
        guard changed else { return }
        cancelScan()
        if AppState.isMoleTab(tabID) { cancelRemoval(showNote: false) }
        activity.identitiesByTab.removeValue(forKey: tabID)
        if AppState.isMoleTab(tabID) { activity.bindingsByTab.removeValue(forKey: tabID) }
    }

    private func startScan() {
        let isMole = AppState.isMoleTab(tabID)
        guard !isMole || !isRemoving else { return }
        if isMole { cancelRemoval(showNote: false) }
        synchronizeScope()
        if isMole, let error = appState.refreshProtections() {
            clearMolePreview(note: "Cleanup is blocked because protection settings could not be verified: \(error)")
            isScanning = false
            activity.isScanning = false
            return
        }
        let protectionsAtStart = isMole ? appState.whitelist : nil
        scanTask?.cancel()
        let requestID = UUID()
        scanRequestID = requestID
        isScanning = true
        activity.isScanning = true
        let started = Date.now
        if isMole { appState.deselect(appState.results(for: tabID).map(\.id)) }
        else { appState.clearSelection() }
        scanTask = Task {
            let found = await runScan()
            guard requestID == scanRequestID else { return }
            guard !Task.isCancelled else {
                isScanning = false
                activity.isScanning = false
                return
            }

            if isMole {
                if let error = appState.refreshProtections() {
                    clearMolePreview(note: "Cleanup is blocked because protection settings could not be verified: \(error)")
                    isScanning = false
                    activity.isScanning = false
                    return
                }
                guard appState.whitelist == protectionsAtStart else {
                    clearMolePreview(note: "Protection settings changed during the scan. Rescan before reviewing or removing items.")
                    isScanning = false
                    activity.isScanning = false
                    return
                }
            }

            let activeWhitelist = protectionsAtStart ?? appState.whitelist
            // Filter through SafetyGate BEFORE showing (fail closed).
            let safe = SafetyGate.filterAllowed(found, whitelist: activeWhitelist)
            appState.resultsByTab[tabID] = safe
            var identities: [String: FileIdentity] = [:]
            var bindings: [String: PathBinding] = [:]
            for row in safe {
                if identities[row.path] == nil, let identity = FileIdentity.read(path: row.path) {
                    identities[row.path] = identity
                }
                if isMole, bindings[row.path] == nil, let binding = PathBinding.read(path: row.path) {
                    bindings[row.path] = binding
                }
            }
            activity.identitiesByTab[tabID] = identities
            if isMole { activity.bindingsByTab[tabID] = bindings }
            await OperationLog.shared.record("[\(tabID)] Previewed \(safe.count) items")
            guard !Task.isCancelled, requestID == scanRequestID else { return }
            refreshToken += 1
            isScanning = false
            activity.recordScan(started: started)
        }
    }

    private func clearMolePreview(note: String) {
        appState.deselect(appState.results(for: tabID).map(\.id))
        appState.resultsByTab.removeValue(forKey: tabID)
        appState.advisoriesByTab.removeValue(forKey: tabID)
        appState.setScanNote(note, for: tabID)
        activity.identitiesByTab.removeValue(forKey: tabID)
        activity.bindingsByTab.removeValue(forKey: tabID)
    }

    private func toggle(_ item: ScanResult) {
        appState.toggleSelection(item.id)
    }

    private func beginMoleConfirmation() {
        guard AppState.isMoleTab(tabID), !isRemoving, !appState.dryRunEnabled else { return }
        if let error = appState.refreshProtections() {
            appState.setScanNote("Cleanup is blocked because protection settings could not be verified: \(error)", for: tabID)
            return
        }
        let rows = appState.results(for: tabID)
        let selectedIDs = Set(appState.selectedResults(for: tabID).map(\.id))
        let review = MoleRemovalReview(
            rows: rows,
            selectedIDs: selectedIDs,
            scanScope: appState.scanScopesByTab[tabID],
            whitelist: appState.whitelist,
            identitiesByPath: activity.identitiesByTab[tabID] ?? [:],
            bindingsByPath: activity.bindingsByTab[tabID] ?? [:]
        )
        if let reason = review.refusalReason(
            currentRows: rows,
            currentSelectedIDs: selectedIDs,
            currentScope: appState.scanScopesByTab[tabID],
            currentWhitelist: appState.whitelist,
            currentIdentitiesByPath: activity.identitiesByTab[tabID] ?? [:],
            currentBindingsByPath: activity.bindingsByTab[tabID] ?? [:],
            previewEnabled: appState.dryRunEnabled
        ) {
            appState.setScanNote(reason, for: tabID)
            return
        }
        pendingMoleReview = review
        showConfirm = true
    }

    private func confirmMoleRemoval() {
        guard AppState.isMoleTab(tabID), !isRemoving, let review = pendingMoleReview else { return }
        guard !appState.dryRunEnabled else {
            cancelRemoval(showNote: false)
            appState.setScanNote("Preview is on; nothing was moved.", for: tabID)
            return
        }
        if let error = appState.refreshProtections() {
            cancelRemoval(showNote: false)
            appState.setScanNote("Cleanup is blocked because protection settings could not be verified: \(error)", for: tabID)
            return
        }
        if let reason = review.refusalReason(
            currentRows: appState.results(for: tabID),
            currentSelectedIDs: Set(appState.selectedResults(for: tabID).map(\.id)),
            currentScope: appState.scanScopesByTab[tabID],
            currentWhitelist: appState.whitelist,
            currentIdentitiesByPath: activity.identitiesByTab[tabID] ?? [:],
            currentBindingsByPath: activity.bindingsByTab[tabID] ?? [:],
            previewEnabled: appState.dryRunEnabled
        ) {
            cancelRemoval(showNote: false)
            appState.setScanNote(reason, for: tabID)
            return
        }
        guard tabID == "analyze" || moleRemovalValidator != nil else {
            cancelRemoval(showNote: false)
            appState.setScanNote("The producing cleanup rule cannot be rechecked; nothing was moved.", for: tabID)
            return
        }

        let selectedRows = review.rows.filter { review.selectedIDs.contains($0.id) }
        let reviewedByPath = Dictionary(uniqueKeysWithValues: selectedRows.map { ($0.path, $0) })
        let validator = moleRemovalValidator
        let manualAnalyze = tabID == "analyze"
        let operationID = UUID()
        removalRequestID = operationID
        isRemoving = true
        isCancellingRemoval = false
        showConfirm = false
        removalTask = Task {
            let report = await DeletePipeline().trash(
                paths: selectedRows.map(\.path),
                whitelist: review.whitelist,
                expectedIdentities: review.identitiesByPath,
                expectedBindings: review.bindingsByPath,
                requirePreviewIdentity: true,
                enforceCleanupSafety: true,
                additionalValidation: { path in
                    guard !Task.isCancelled else { return "Removal cancelled before validation." }
                    if manualAnalyze {
                        return await CleanupRemovalValidator.manualAnalyzeProtectionReason(
                            for: path, whitelist: review.whitelist
                        )
                    }
                    guard let row = reviewedByPath[path], let validator else {
                        return "The reviewed cleanup source is missing; item kept."
                    }
                    return await validator(row, review.whitelist)
                }
            )
            activity.recordRemoval(report)
            let settled = appState.applyMoleRemoval(report, to: tabID)
            activity.identitiesByTab[tabID] = (activity.identitiesByTab[tabID] ?? [:])
                .filter { !settled.contains($0.key) }
            activity.bindingsByTab[tabID] = (activity.bindingsByTab[tabID] ?? [:])
                .filter { !settled.contains($0.key) }
            let size = TeboBytes.text(report.freedBytes)
            let summary = "Moved \(report.trashedCount) items to Trash (logical size \(size)); skipped \(report.skippedCount), failed \(report.failedCount)."
            appState.setScanNote(Task.isCancelled ? "Removal cancelled. \(summary)" : summary, for: tabID)
            if removalRequestID == operationID {
                removalTask = nil
                pendingMoleReview = nil
                isRemoving = false
                isCancellingRemoval = false
            }
        }
    }

    private func cancelRemoval(showNote: Bool) {
        showConfirm = false
        pendingMoleReview = nil
        guard let task = removalTask else {
            removalRequestID = UUID()
            isRemoving = false
            isCancellingRemoval = false
            return
        }
        guard !isCancellingRemoval else { return }
        isCancellingRemoval = true
        task.cancel()
        if showNote {
            appState.setScanNote("Cancellation requested. Any items already moved remain recoverable from the Trash.", for: tabID)
        }
    }

    private func trashSelected() {
        let paths = appState.selectedResults(for: tabID).map(\.path)
        Task {
            if appState.dryRunEnabled {
                await OperationLog.shared.record("[\(tabID)] Dry-run: would trash \(paths.count) items")
            } else {
                let report = await DeletePipeline().trash(paths: paths, whitelist: appState.whitelist,
                    expectedIdentities: activity.identitiesByTab[tabID] ?? [:], additionalValidation: removalValidator)
                appState.setScanNote(report.summary, for: tabID)
                activity.recordRemoval(report)
                let moved = Set(report.outcomes.compactMap { outcome -> String? in
                    if case .trashed = outcome.result { return outcome.path }
                    return nil
                })
                appState.resultsByTab[tabID] = appState.results(for: tabID)
                    .filter { !moved.contains($0.path) }
                appState.clearSelection()
            }
        }
    }
}
