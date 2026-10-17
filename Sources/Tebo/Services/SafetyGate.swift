import Darwin
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
        case protectedUserData = "mandatory user-data protection"
        case dataContainerRoot = "whole application data container"
    }

    // MARK: - Protected locations (never delete)

    /// Exact deny entries from Mole's `_mole_is_critical_deletion_path`:
    /// the path itself is refused, children are not.
    private static let exactDenies = Set([
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
    ].map { $0.lowercased() })

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
    ].map { $0.lowercased() }

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
    ].map { $0.lowercased() }

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

    /// Protected ancestors may be inspected for eligible leaves, never removed themselves.
    public static func isAllowedToTraverse(path: String, whitelist: Set<String>) -> Bool {
        let reason = rejectionReason(path: path, whitelist: whitelist, includeProtectedAncestors: false)
        return reason == nil || reason == .dataContainerRoot
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
    static func rejectionReason(path: String, whitelist: Set<String>, includeProtectedAncestors: Bool = true) -> RejectionReason? {
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
        let foldedPath = normalized(path).lowercased()
        for entry in whitelist where !entry.isEmpty {
            let expanded = (entry as NSString).expandingTildeInPath
            let foldedEntry = (expanded.hasPrefix("/") ? normalized(expanded) : expanded).lowercased()
            if foldedPath.contains(entry.lowercased()) || foldedPath.contains(foldedEntry) { return .whitelisted }
            if includeProtectedAncestors, expanded.hasPrefix("/"), normalized(expanded).lowercased().hasPrefix(foldedPath + "/") {
                return .whitelisted // Removing a parent would also remove this protected child.
            }
        }

        // 6. Critical system paths, matched on the normalized literal so
        //    "//" and "/./" cosmetics cannot slip past the list.
        if isCriticalSystemPath(normalized(path)) {
            let parts = foldedPath.split(separator: "/")
            let collection = parts.dropFirst(2).joined(separator: "/")
            let inspectable = parts.count > 2 && parts[0] == "users" && parts[1] != "guest"
                && ["library/containers", "library/group containers", "library/caches", "library/logs"].contains(collection)
            // Collection roots authorize discovery only, never removal of protected descendants.
            if includeProtectedAncestors || !inspectable { return .criticalSystemPath }
        }

        // 7. Apple-owned fragments.
        if containsAppleSystemFragment(path) { return .appleSystemFragment }

        if containsMandatoryProtectedData(path, includeAncestors: includeProtectedAncestors) { return .protectedUserData }
        if isWholeDataContainer(path) { return .dataContainerRoot }

        return nil
    }

    // These are always applied, independently of the editable convenience exclusions.
    // Adapted from Mole base.sh SAFETY_WHITELIST_PATTERNS, with stricter local backup/model guards:
    // https://github.com/tw93/Mole/blob/0d92da5c855af23310cc1d19a6fb5a713c0bc2c8/lib/core/base.sh#L188-L212
    private static let mandatoryTrees: [[String]] = [
        "Library/Caches/CloudKit*", "Library/Caches/pypoetry/virtualenvs*",
        "Library/Caches/org.R-project.R/R/renv", ".cache/pypoetry/virtualenvs*",
        "Library/Application Support/MobileSync", "Library/Mobile Documents",
        "Library/CloudStorage", "Library/Logs/tebo", ".ollama/models"
    ].map { $0.lowercased().split(separator: "/").map(String.init) }

    static func containsMandatoryProtectedData(_ path: String, includeAncestors: Bool = true) -> Bool {
        let parts = normalized(path).lowercased().split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasSuffix(".photoslibrary") || $0.hasSuffix(".photolibrary")
            || $0.hasSuffix(".mlmodelc") }) { return true }
        for pattern in mandatoryTrees {
            for index in parts.indices where parts[index] == pattern[0] {
                let remaining = parts[index...]
                if !includeAncestors, remaining.count < pattern.count { continue }
                // The tree patterns are home-relative, so an ancestor match
                // (path shorter than the pattern) is only meaningful at the
                // user's own Library (<home>/Library...). Without that anchor,
                // any deep directory literally named "Library" would deny its
                // entire parent: iOS DeviceSupport stores its payload under
                // Symbols/System/Library inside each version directory.
                if remaining.count < pattern.count, index != 2 || parts[0] != "users" { continue }
                let overlap = min(remaining.count, pattern.count)
                // A parent removal would also remove the protected descendant, even if it was
                // not present at scan time. Siblings outside this prefix remain eligible.
                if zip(remaining.prefix(overlap), pattern.prefix(overlap)).allSatisfy({
                    fnmatch($0.1, $0.0, FNM_PATHNAME) == 0
                }) { return true }
            }
        }
        // A container's Data/Library/Caches is an aggregate cache root: never a
        // removal candidate, always traversable. The DeviceSupport payload
        // (Symbols/System/Library/Caches) is tool content and stays cleanable.
        if includeAncestors, parts.count >= 3, Array(parts.suffix(3)) == ["data", "library", "caches"] {
            return true
        }
        return false
    }

    private static func isWholeDataContainer(_ path: String) -> Bool {
        let parts = normalized(path).lowercased().split(separator: "/")
        guard parts.count >= 3 else { return false }
        let tail = Array(parts.suffix(3))
        return tail[0] == "library" && ["containers", "group containers"].contains(tail[1])
    }

    /// Deny list against an already-normalized, absolute path.
    static func isCriticalSystemPath(_ path: String) -> Bool {
        // Deny-only case folding closes aliases on case-insensitive APFS without rewriting input.
        let path = path.lowercased()
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
        if path.hasPrefix("/users/") {
            let rest = String(path.dropFirst("/users/".count))
            if !rest.isEmpty, !rest.contains("/") { return true }
            let components = rest.split(separator: "/")
            let relative = components.dropFirst().joined(separator: "/").lowercased()
            if userRootDirectories.contains(relative) { return true }
            if userProtectedTrees.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { return true }
        }

        return false
    }

    /// Whole user-data roots and credentials are not cleanup candidates. Cache children remain usable.
    static let userRootDirectoryNames: Set<String> = [
        "Library", "Library/Application Support", "Library/Containers", "Library/Group Containers",
        "Library/Preferences", "Library/Caches", "Library/Logs", "Library/Saved Application State", ".config", ".local"
    ]
    static let userProtectedTreeNames: Set<String> = [".ssh", ".gnupg", "Library/Keychains"]
    private static let userRootDirectories = Set(userRootDirectoryNames.map { $0.lowercased() })
    private static let userProtectedTrees = Set(userProtectedTreeNames.map { $0.lowercased() })

    /// Apple-system fragments. Separate from the deny list so PathValidator
    /// can re-run them on symlink-resolved paths too.
    static func containsAppleSystemFragment(_ path: String) -> Bool {
        let folded = normalized(path).lowercased()
        return blockedFragments.contains(where: { folded.contains($0) })
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
