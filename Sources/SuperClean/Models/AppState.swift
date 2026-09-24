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
    /// Loaded from ~/.config/superclean/whitelist on launch.
    var whitelist: Set<String> = []

    /// Detected state of the bundled czkawka engine (presence + hash verification).
    var engine: EngineStatus = .missing

    /// Absolute path to ffmpeg when one is installed. Gates similar videos and video checks.
    var ffmpegPath: String?

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
    /// Small in M1 (mock data). Streams real engine output in M2/M3.
    var resultsByTab: [String: [ScanResult]] = [:]

    /// Which result rows the user ticked for deletion.
    var selectedIDs: Set<UUID> = []

    // MARK: Helpers

    /// Results for one tab (empty array if never scanned).
    func results(for tab: String) -> [ScanResult] {
        resultsByTab[tab] ?? []
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
