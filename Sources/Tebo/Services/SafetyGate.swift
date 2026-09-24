import Foundation

// MARK: - SafetyGate
// THE most important file in the app.
// Every delete must pass through here. No exceptions.
// Mirrors Mole's rules (validate_path_for_deletion + _mole_is_critical_deletion_path
// in lib/core/file_ops.sh): traversal, control characters, the critical-path
// deny list, plus the whitelist and Trash-only semantics.

// Design constraint: SafetyGate is PURE STRING LOGIC. No FileManager, no
// stat, no symlink resolution. Scans filter thousands of candidate rows
// through isAllowed at display time, so it must stay cheap. The half of
// Mole's pipeline that needs the filesystem (symlink target resolution,
// same-inode guards) lives in PathValidator, which DeletePipeline runs once
// per path immediately before a move to Trash.

/// Central safety checker. Pure logic, no UI, easy to unit-test.
/// All methods are static + Sendable so any Task can call them cheaply.
public enum SafetyGate {

    // MARK: - Rejection reasons

    /// Why a path was refused by the string rules. Internal on purpose:
    /// PathValidator maps these onto its public Reason set, and the UI only
    /// ever sees reasons through DeleteReport.
    enum RejectionReason: String, Sendable, CaseIterable {
        case emptyPath = "empty path"
        case relativePath = "path is not absolute"
        case pathTraversal = "path contains a .. component"
        case controlCharacters = "path contains control characters"
        case whitelisted = "user whitelisted"
        case criticalSystemPath = "critical system path"
        case appleSystemFragment = "Apple system data fragment"
    }

    // MARK: - Protected locations (never delete)

    /// Exact deny entries from Mole's `_mole_is_critical_deletion_path`:
    /// the path itself is refused, children are not.
    private static let exactDenies: [String] = [
        "/", "/bin", "/dev", "/sbin", "/usr", "/System",
        "/Library", "/Applications", "/Volumes", "/opt", "/opt/homebrew",
        "/Users", "/Users/Shared", "/Users/Guest",
        "/private", "/private/tmp", "/etc", "/private/etc",
        "/var", "/var/db", "/var/audit", "/var/root",
        "/private/var", "/private/var/tmp", "/private/var/folders",
        "/private/var/db", "/private/var/audit", "/private/var/root",
        "/Library/Apple", "/Library/Application Support",
        "/Library/Extensions", "/Library/Keychains",
        "/Applications/Finder.app", "/Applications/Safari.app",
        // App extras (kept from the original SafetyGate):
        "/Library/Updates",           // Software Update staging — read-only
        "/macOS Install Data"         // Big Sur+ update staging
    ]

    /// Subtree deny entries: the path AND everything below it is refused.
    /// Note: Mole only touches /Library via sudo. Tebo has no
    /// privileged path, so the whole /Library tree is denied (fail closed).
    /// That is why the task's boundary tests block /Library/Caches/x even
    /// though Mole's own case list would not.
    private static let subtreeDenies: [String] = [
        "/bin/", "/dev/", "/sbin/", "/usr/", "/System/",
        "/Library/",
        "/Library/Apple/", "/Library/Extensions/", "/Library/Keychains/",
        "/Users/Guest/",
        "/etc/", "/private/etc/",
        "/var/db/", "/var/audit/",
        "/private/var/db/", "/private/var/audit/",
        "/Applications/Finder.app/", "/Applications/Safari.app/",
        // App extras:
        "/Library/Updates/",
        "/private/var/db/powerlog/", // Active PowerLog DB — read-only (Mole rule)
        "/macOS Install Data/"
    ]

    /// Carve-outs inside a denied subtree that Mole keeps deletable.
    /// Homebrew (Intel) lives in /usr/local, Apple Silicon in /opt/homebrew:
    /// the ROOTS are denied above but individual cells are not. Trailing
    /// slash is load-bearing: only real children match, never the root.
    private static let deletableSubtreeCarveOuts: [String] = [
        "/usr/local/",
        "/opt/homebrew/"
    ]

    /// Bundle IDs / path fragments that mean "Apple system data".
    private static let blockedFragments: [String] = [
        "com.apple.",
        "Preferences/ByHost" // Machine-specific plists, too risky
    ]

    // MARK: - Public API

    /// Returns `true` if this path is allowed to be cleaned.
    /// - Parameters:
    ///   - path: Full file path, e.g. "/Users/me/Library/Caches/Chrome"
    ///   - whitelist: User-protected substrings (substring match = skip).
    ///     Entries starting with `~` are expanded to the home dir first,
    ///     so `~/Library/Caches/x` protects as users expect.
    public static func isAllowed(path: String, whitelist: Set<String>) -> Bool {
        rejectionReason(path: path, whitelist: whitelist) == nil
    }

    /// Filters a batch, keeping only safe items. Fast O(n) pass.
    public static func filterAllowed(
        _ items: [ScanResult],
        whitelist: Set<String>
    ) -> [ScanResult] {
        items.filter { isAllowed(path: $0.path, whitelist: whitelist) }
    }

    // MARK: - Rule machinery (used by PathValidator + DeletePipeline)

    /// Typed string-level rejection, or nil when the path passes. Ordered
    /// like Mole's validate_path_for_deletion: structure first, then policy.
    static func rejectionReason(path: String, whitelist: Set<String>) -> RejectionReason? {
        // 1. Empty or root? Never.
        guard !path.isEmpty else { return .emptyPath }

        // 2. Absolute only.
        guard path.hasPrefix("/") else { return .relativePath }

        // 3. Traversal: ".." as a complete path component, not a substring.
        //    (Firefox legitimately names dirs "name..files".)
        if path.split(separator: "/", omittingEmptySubsequences: true).contains("..") {
            return .pathTraversal
        }

        // 4. Control characters (C0/C1/DEL, incl. newlines and tabs).
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .controlCharacters
        }

        // 5. User whitelist (substring match; ~ expanded; blanks ignored).
        for entry in whitelist where !entry.isEmpty {
            if path.contains(entry) { return .whitelisted }
            if entry.hasPrefix("~"),
               path.contains((entry as NSString).expandingTildeInPath) { return .whitelisted }
        }

        // 6. Critical system paths, matched on the normalized literal so
        //    "//" and "/./" cosmetics cannot slip past the list.
        if isCriticalSystemPath(normalized(path)) { return .criticalSystemPath }

        // 7. Apple-owned fragments.
        if containsAppleSystemFragment(path) { return .appleSystemFragment }

        return nil
    }

    /// Deny list against an already-normalized, absolute path.
    static func isCriticalSystemPath(_ path: String) -> Bool {
        if exactDenies.contains(path) { return true }

        for root in subtreeDenies where path.hasPrefix(root) {
            // Mole: "/usr/local/* | /opt/homebrew/*) return 1" — individual
            // Homebrew cells stay deletable, the roots above do not.
            if deletableSubtreeCarveOuts.contains(where: { path.hasPrefix($0) }) { continue }
            return true
        }

        // Reject a whole user home (/Users/<name>): exactly one component
        // under /Users. Bash cannot express this in one glob; it matches one
        // level. Catches the empty-variable collapse "$user/$leaf" ->
        // "/Users/<name>" that would hand rm an entire home directory.
        if path.hasPrefix("/Users/") {
            let rest = String(path.dropFirst("/Users/".count))
            if !rest.isEmpty, !rest.contains("/") { return true }
        }

        return false
    }

    /// Apple-system fragments. Separate from the deny list so PathValidator
    /// can re-run them on symlink-resolved paths too.
    static func containsAppleSystemFragment(_ path: String) -> Bool {
        blockedFragments.contains(where: { path.contains($0) })
    }

    /// Collapse "//" and "/./" like Mole's _mole_normalize_deletion_policy_path.
    /// ".." is never resolved here: paths containing it are rejected earlier.
    static func normalized(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        guard !parts.isEmpty else { return "/" }
        return "/" + parts.joined(separator: "/")
    }
}
