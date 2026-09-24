import Foundation

// MARK: - SafetyGate
// THE most important file in the app.
// Every delete must pass through here. No exceptions.
// Mirrors Mole's rules: protected paths + whitelist + Trash-only.

/// Central safety checker. Pure logic, no UI, easy to unit-test.
/// All methods are static + Sendable so any Task can call them cheaply.
public enum SafetyGate {

    // MARK: Protected locations (never delete)

    /// Path prefixes we refuse to touch, even if an engine suggests them.
    /// Based on Mole's `should_protect_path` + Apple system locations.
    private static let blockedPrefixes: [String] = [
        "/System",
        "/Library/Apple",
        "/private/var/db/powerlog", // Active PowerLog DB — read-only (Mole rule)
        "/Library/Updates",         // Software Update staging — read-only
        "/macOS Install Data"
    ]

    /// Bundle IDs / path fragments that mean "Apple system data".
    private static let blockedFragments: [String] = [
        "com.apple.",
        "Preferences/ByHost" // Machine-specific plists, too risky
    ]

    // MARK: Public API

    /// Returns `true` if this path is allowed to be cleaned.
    /// - Parameters:
    ///   - path: Full file path, e.g. "/Users/me/Library/Caches/Chrome"
    ///   - whitelist: User-protected substrings (substring match = skip).
    ///     Entries starting with `~` are expanded to the home dir first,
    ///     so `~/Library/Caches/x` protects as users expect.
    public static func isAllowed(path: String, whitelist: Set<String>) -> Bool {
        // 1. Empty or root? Never.
        guard !path.isEmpty, path != "/" else { return false }

        // 2. User whitelist wins first (explicit protection).
        for entry in whitelist where !entry.isEmpty {
            if path.contains(entry) { return false }
            // Expand a leading ~ so home-relative entries actually match.
            if entry.hasPrefix("~"),
               path.contains((entry as NSString).expandingTildeInPath) { return false }
        }

        // 3. System prefixes — fail closed.
        for prefix in blockedPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") { return false }
        }

        // 4. Apple-owned fragments.
        for fragment in blockedFragments {
            if path.contains(fragment) { return false }
        }

        return true
    }

    /// Filters a batch, keeping only safe items. Fast O(n) pass.
    public static func filterAllowed(
        _ items: [ScanResult],
        whitelist: Set<String>
    ) -> [ScanResult] {
        items.filter { isAllowed(path: $0.path, whitelist: whitelist) }
    }
}
