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
    var whitelist: Set<String> = []

    /// Detected state of the bundled czkawka engine (presence + hash verification).
    var engine: EngineStatus = .missing

    /// Path to ffmpeg when one is installed. Gates similar videos and video checks.
    var ffmpegPath: String?

    /// nil until probed. Full Disk Access is inferred by reading a protected path (PermissionProbe).
    var hasFullDiskAccess: Bool?

    init() {
        // Tiny file read on launch — safe on the main thread.
        self.whitelist = WhitelistStore.load()
    }

    /// Probe external tooling. Verifying the engine reads and hashes ~27 MB, so it stays off the
    /// main actor: Settings and the scan tabs call this on appear.
    func refreshTooling() async {
        let status = await Task.detached(priority: .utility) { EngineLocator.locate() }.value
        engine = status
        ffmpegPath = EngineLocator.findFFmpeg()
        hasFullDiskAccess = await Task.detached(priority: .utility) {
            PermissionProbe.hasFullDiskAccess()
        }.value
    }

    /// Add protection + persist. Ignores blank entries.
    func addWhitelist(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        whitelist.insert(trimmed)
        WhitelistStore.save(whitelist)
    }

    /// Remove protection + persist.
    func removeWhitelist(_ entry: String) {
        whitelist.remove(entry)
        WhitelistStore.save(whitelist)
    }

    /// Last scan results per tab, keyed by tab id ("clean", "duplicates"...).
    /// Populated by each tab's real scan; rows are lazy-rendered, so this holds metadata only.
    var resultsByTab: [String: [ScanResult]] = [:]

    /// Rows a scan found but this app must NOT delete (needs root, report-only, app running).
    /// Kept apart from resultsByTab so they can never be selected for deletion.
    var advisoriesByTab: [String: [AdvisoryRow]] = [:]

    /// One-line note about the last scan (absent locations, early stop, engine trouble).
    var scanNotesByTab: [String: String] = [:]

    /// Which result rows the user ticked for deletion.
    var selectedIDs: Set<UUID> = []

    // MARK: Helpers

    /// Results for one tab (empty array if never scanned).
    func results(for tab: String) -> [ScanResult] {
        resultsByTab[tab] ?? []
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
}
