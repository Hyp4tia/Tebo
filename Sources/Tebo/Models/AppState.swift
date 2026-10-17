import Foundation
import Observation

// MARK: - AppState
// Single source of truth for the whole app.
// @Observable (not ObservableObject) = modern, less boilerplate, faster.

/// Global UI state shared by all 6 tabs.
/// Always touched on the main thread (@MainActor).
@Observable
@MainActor
final class AppState {

    // MARK: Global settings

    /// When true, scans only PREVIEW. Nothing is deleted.
    /// Keep ON until the user explicitly confirms.
    var dryRunEnabled: Bool = true

    /// User-protected path substrings, e.g. "~/Library/Caches/com.myapp".
    /// Loaded from ~/.config/tebo/whitelist on launch.
    var whitelist: Set<String> = [] {
        didSet {
            if whitelist != oldValue { invalidateMolePreviews() }
        }
    }
    private(set) var protectionError: String?
    @ObservationIgnored private let whitelistURL: URL?

    /// Detected state of the bundled czkawka engine (presence + hash verification).
    var engine: EngineStatus = .missing

    /// Path to ffmpeg when one is installed. Gates similar videos and video checks.
    var ffmpegPath: String?

    /// nil until probed. Full Disk Access is inferred by reading a protected path (PermissionProbe).
    var hasFullDiskAccess: Bool?

    init(whitelistURL: URL? = nil) {
        // Tiny file read on launch — safe on the main thread.
        self.whitelistURL = whitelistURL
        let snapshot = WhitelistStore.snapshot(from: whitelistURL)
        self.whitelist = snapshot.entries
        self.protectionError = snapshot.error
    }

    @discardableResult
    func refreshProtections() -> String? {
        guard protectionError == nil else { return protectionError }
        let snapshot = WhitelistStore.snapshot(from: whitelistURL)
        whitelist = snapshot.entries
        protectionError = snapshot.error
        return protectionError
    }

    func reloadProtections() {
        protectionError = nil
        refreshProtections()
    }

    private func invalidateMolePreviews() {
        for tab in Array(resultsByTab.keys) where Self.isMoleTab(tab) {
            selectedIDs.subtract(results(for: tab).map(\.id))
            resultsByTab.removeValue(forKey: tab)
            advisoriesByTab.removeValue(forKey: tab)
            scanNotesByTab[tab] = "Protection settings changed. Rescan before removing anything."
        }
        folderAnalysis = nil
    }

    /// Probe external tooling. Verifying the engine reads and hashes ~27 MB, so it stays off the
    /// main actor: Settings and the scan tabs call this on appear.
    func refreshTooling() async {
        let status = await Task.detached(priority: .utility) { EngineLocator.locate() }.value
        engine = status
        ffmpegPath = EngineLocator.findFFmpeg()
        await refreshPermissions()
    }

    /// Returning from System Settings must refresh the access observation, even
    /// when the window and scanner tooling have not been recreated.
    func refreshPermissions(probe: @escaping @Sendable () -> Bool = { PermissionProbe.hasFullDiskAccess() }) async {
        hasFullDiskAccess = await Task.detached(priority: .utility, operation: probe).value
    }

    /// Add protection + persist. Ignores blank entries.
    func addWhitelist(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, refreshProtections() == nil else { return }
        persistProtections(whitelist.union([trimmed]))
    }

    /// Remove protection + persist.
    func removeWhitelist(_ entry: String) {
        guard refreshProtections() == nil else { return }
        persistProtections(whitelist.subtracting([entry]))
    }

    private func persistProtections(_ entries: Set<String>) {
        if let error = WhitelistStore.save(entries, to: whitelistURL) {
            // A failed save must not claim the user's new protection has taken effect.
            protectionError = error
            invalidateMolePreviews()
            return
        }
        whitelist = entries
    }

    /// Last scan results per tab, keyed by tab id ("clean", "duplicates"...).
    /// Populated by each tab's real scan; rows are lazy-rendered, so this holds metadata only.
    var resultsByTab: [String: [ScanResult]] = [:]

    /// Rows a scan found but this app must NOT delete (needs root, report-only, app running).
    /// Kept apart from resultsByTab so they can never be selected for deletion.
    var advisoriesByTab: [String: [AdvisoryRow]] = [:]

    /// One-line note about the last scan (absent locations, early stop, engine trouble).
    var scanNotesByTab: [String: String] = [:]

    /// Locations associated with a tab's cached scan. A folder change invalidates that scan.
    var scanScopesByTab: [String: [String]] = [:]
    var analysisRoot = NSHomeDirectory()
    var folderAnalysis: FolderAnalysis?

    /// Which result rows the user ticked for deletion.
    var selectedIDs: Set<UUID> = []

    /// Group id per result row, for the grouped tools (duplicates, similar media). Held here
    /// rather than in the tab because the tab's own state does not survive leaving the tab.
    var groupByRowID: [UUID: String] = [:]

    /// Engine-reported extras per row (pixel dimensions, difference score, tags) for the tools
    /// whose rows show previews. Populated by the Duplicates tab's scan.
    var mediaDetailByRowID: [UUID: CzkawkaItemDetail] = [:]

    // MARK: Helpers

    @discardableResult
    func updateScanScope(_ scope: [String], for tab: String) -> Bool {
        guard scanScopesByTab[tab] != scope else { return false }
        let oldIDs = Set(results(for: tab).map(\.id))
        selectedIDs.subtract(oldIDs)
        groupByRowID = groupByRowID.filter { !oldIDs.contains($0.key) }
        mediaDetailByRowID = mediaDetailByRowID.filter { !oldIDs.contains($0.key) }
        resultsByTab.removeValue(forKey: tab)
        advisoriesByTab.removeValue(forKey: tab)
        scanNotesByTab.removeValue(forKey: tab)
        if tab == "analyze" { folderAnalysis = nil }
        scanScopesByTab[tab] = scope
        return true
    }

    /// Results for one tab (empty array if never scanned).
    func results(for tab: String) -> [ScanResult] {
        resultsByTab[tab] ?? []
    }

    /// Settled Mole items require a fresh scan before they can be selected again.
    @discardableResult
    func applyMoleRemoval(_ report: DeleteReport, to tab: String) -> Set<String> {
        let settled = Set(report.outcomes.map(\.path))
        let rows = results(for: tab)
        selectedIDs.subtract(rows.filter { settled.contains($0.path) }.map(\.id))
        resultsByTab[tab] = rows.filter { !settled.contains($0.path) }
        let kept = report.outcomes.compactMap { outcome -> AdvisoryRow? in
            let detail: String
            switch outcome.result {
            case .trashed: return nil
            case .skipped(let reason): detail = reason.displayText
            case .failed(let message): detail = "Move failed: \(message). Item kept; rescan before retrying."
            }
            return AdvisoryRow(id: outcome.path, title: URL(fileURLWithPath: outcome.path).lastPathComponent,
                               detail: detail, source: outcome.path, group: "Kept after removal review")
        }
        advisoriesByTab[tab, default: []].append(contentsOf: kept)
        return settled
    }

    func results(forTabs tabs: [String]) -> [ScanResult] {
        var seen: Set<String> = []
        return tabs.flatMap { results(for: $0) }.filter { seen.insert($0.path).inserted }
    }

    /// Advisory rows for one tab.
    func advisories(for tab: String) -> [AdvisoryRow] {
        advisoriesByTab[tab] ?? []
    }

    /// Note for one tab, nil when the last scan had nothing to report.
    func scanNote(for tab: String) -> String? {
        scanNotesByTab[tab]
    }

    /// Set a tab's note directly. Used by tabs that run an external engine and have their own
    /// failure wording (a failed engine run must never read as an empty result).
    func setScanNote(_ note: String?, for tab: String) {
        scanNotesByTab[tab] = note
    }

    /// Record a table sweep's side output. Deletable rows are returned to the caller separately
    /// (they go through SafetyGate before they reach resultsByTab).
    func apply(_ outcome: MoleScanOutcome, to tab: String) {
        advisoriesByTab[tab] = outcome.advisories
        var notes: [String] = []
        if outcome.absentLocationCount > 0 {
            notes.append("\(outcome.absentLocationCount) known locations are not present on this Mac")
        }
        if outcome.truncated {
            notes.append("the list stopped early, so it may be partial")
        }
        scanNotesByTab[tab] = notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    /// Selected results for one tab only.
    func selectedResults(for tab: String) -> [ScanResult] {
        results(for: tab).filter { selectedIDs.contains($0.id) }
    }

    /// Total bytes the user is about to delete in this tab.
    func selectedBytes(for tab: String) -> Int64 {
        selectedResults(for: tab).reduce(0) { $0 + $1.sizeBytes }
    }

    /// Clear selection (call after scan finishes or tab switches).
    func clearSelection() {
        selectedIDs.removeAll()
    }

    // MARK: Selection commands (the buttons in every results tab)

    /// Tick every row this tab currently lists.
    func selectAll(for tab: String) {
        selectedIDs.formUnion(results(for: tab).map(\.id))
    }

    /// Tick exactly the rows their own scanner marked as a safe default.
    func selectRecommended(for tab: String, visibleIDs: Set<UUID>? = nil) {
        // Selecting everything first must not leave manual-review items ticked in Mole tabs.
        if Self.isMoleTab(tab) { selectedIDs.subtract(results(for: tab).map(\.id)) }
        selectedIDs.formUnion(results(for: tab).filter {
            $0.recommendedForSelection && (visibleIDs?.contains($0.id) ?? true)
        }.map(\.id))
    }

    static func isMoleTab(_ tab: String) -> Bool {
        ["clean", "purge", "installer", "analyze", "uninstall"].contains(tab) || tab.hasPrefix("maintenance-")
    }

    /// Tick a specific set of rows (per-group "select all", keep-one-per-group).
    func select(_ ids: some Sequence<UUID>) {
        selectedIDs.formUnion(ids)
    }

    /// Untick a specific set of rows.
    func deselect(_ ids: some Sequence<UUID>) {
        selectedIDs.subtract(ids)
    }

    /// Flip one row's tick. Shared by every layout so a click means the same thing everywhere.
    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}
