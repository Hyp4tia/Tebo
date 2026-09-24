import Foundation

// MARK: - PathValidator
// Delete-time half of Mole's validation pipeline, ported from
// validate_path_for_deletion (lib/core/file_ops.sh).

// SafetyGate is pure string logic so scan previews stay cheap and disk-free.
// The rules here REQUIRE the filesystem: symlink resolution and same-inode
// comparison against protected roots. DeletePipeline runs this once per path
// immediately before a move, so these stat calls never sit on the display
// hot path (Mole keeps the same split: the ancestor walk stays out of the
// per-candidate sweep).

// Deny-only semantics (same as Mole): resolution can only ever REMOVE
// permission. A path that fails the string rules never reaches the disk
// checks, and a path whose resolved form is dangerous is refused even though
// its literal string looked clean.

/// Leaf identity (device, inode). A file replaced in place gets a new inode,
/// so comparing this detects rename-and-recreate races between validation
/// and delete (Mole's `stat -f%d:%i:%m` recheck in safe_remove).
public struct FileIdentity: Sendable, Equatable, Hashable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// stat()-style read (follows a leaf symlink, like Mole's `stat -f`).
    /// nil when the path is missing or unreadable — callers fail closed.
    static func read(path: String) -> FileIdentity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        return FileIdentity(device: device, inode: inode)
    }
}

/// Full deletion-time validator. Static + Sendable; callable from any Task.
public enum PathValidator {

    // MARK: - Reasons

    /// Why a path was refused. Raw values are UI-ready strings; the first
    /// seven mirror SafetyGate's string rules, the last two are the
    /// filesystem-resolved checks.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        case emptyPath = "empty path"
        case relativePath = "path is not absolute"
        case pathTraversal = "path contains a .. component"
        case controlCharacters = "path contains control characters"
        case whitelisted = "user whitelisted"
        case criticalSystemPath = "critical system path"
        case appleSystemFragment = "Apple system data fragment"
        case symlinkToProtectedPath = "symlink resolves to a protected path"
        case aliasOfProtectedRoot = "same inode as a protected root"
    }

    // MARK: - Protected roots (inode guards)

    /// Only the LEAF itself may not be one of these (Mole's exact_roots).
    /// APFS is case-insensitive but case-preserving: /SYSTEM or /OPT/HOMEBREW
    /// are not symlinks, they are the SAME INODE as the protected roots, so
    /// string rules alone can miss them.
    private static let exactProtectedRoots: Set<String> = [
        "/", "/Applications", "/Library", "/Volumes", "/Network", "/cores",
        "/etc", "/home", "/net", "/tmp", "/var", "/private", "/private/tmp",
        "/private/var", "/private/var/tmp", "/private/var/folders", "/Users",
        "/opt", "/opt/homebrew"
    ]

    /// Neither the leaf NOR any ancestor may be one of these (Mole's
    /// protected_trees).
    private static let protectedTreeRoots: Set<String> = [
        "/bin", "/dev", "/sbin", "/usr", "/System", "/private/etc",
        "/private/var/audit", "/private/var/db", "/private/var/root",
        "/Library/Apple", "/Library/Extensions", "/Library/Keychains",
        "/Applications/Finder.app", "/Applications/Safari.app"
    ]

    // MARK: - Public API

    /// Returns the reason `path` must NOT be deleted, or nil when allowed.
    public static func validate(path: String, whitelist: Set<String>) -> Reason? {
        // 1. String rules first: cheap, and they fail closed before anything
        //    touches the filesystem.
        if let reason = SafetyGate.rejectionReason(path: path, whitelist: whitelist) {
            return map(reason)
        }

        // 2. Symlink resolution (Mole's leaf-symlink + ancestor-symlink
        //    guards). Foundation's resolvingSymlinksInPath refuses to
        //    resolve a path whose final component is missing, so resolve
        //    the PARENT physically (Mole's `cd -P "$parent_dir"`) and
        //    re-append the leaf, then resolve the leaf itself when it is a
        //    symlink. The resolved string is re-checked against the deny
        //    rules: deny-only, a resolved path never grants permission.
        let resolved = resolvedPhysicalPath(of: path)
        if resolved != SafetyGate.normalized(path),
           SafetyGate.isCriticalSystemPath(resolved)
            || SafetyGate.containsAppleSystemFragment(resolved) {
            return .symlinkToProtectedPath
        }

        // 3. Same-inode guards for case-variant aliases (see list comments).
        if isSameInodeAsProtectedRoot(path) { return .aliasOfProtectedRoot }

        return nil
    }

    // MARK: - Symlink resolution

    /// Physical (symlink-free) form of `path`: resolve every ancestor via
    /// the parent directory, then the leaf itself when it is a symlink.
    /// Works for paths whose leaf does not exist yet (a delete candidate
    /// may have vanished between scan and delete), which Foundation's
    /// resolvingSymlinksInPath cannot handle.
    private static func resolvedPhysicalPath(of path: String) -> String {
        let normalizedLiteral = SafetyGate.normalized(path)
        var parent = (normalizedLiteral as NSString).deletingLastPathComponent
        if parent.isEmpty { parent = "/" }
        let leaf = (normalizedLiteral as NSString).lastPathComponent
        var resolved = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
        resolved = (resolved as NSString).appendingPathComponent(leaf)
        // lstat-style leaf check: URL resourceValues does not follow the
        // final symlink, so this is true only when the LEAF itself is a link.
        if let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            resolved = URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
        }
        return resolved
    }

    // MARK: - Inode guards (Mole's -ef same-file checks)

    /// True when the leaf is a protected root, an ancestor of the leaf is a
    /// protected tree root, or the leaf's parent IS /Users (blocks
    /// /USERS/<name> and case variants of /Users/Shared or /Users/Guest).
    private static func isSameInodeAsProtectedRoot(_ path: String) -> Bool {
        let normalizedPath = SafetyGate.normalized(path)

        // Exact roots: the leaf itself.
        if let leafID = FileIdentity.read(path: normalizedPath) {
            for root in exactProtectedRoots where FileIdentity.read(path: root) == leafID {
                return true
            }
        }

        // Tree roots: leaf + every ancestor up to and including "/".
        var probe = normalizedPath
        while true {
            if let id = FileIdentity.read(path: probe) {
                for root in protectedTreeRoots where FileIdentity.read(path: root) == id {
                    return true
                }
            }
            if probe == "/" { break }
            probe = (probe as NSString).deletingLastPathComponent
            if probe.isEmpty { probe = "/" }
        }

        // Parent IS /Users: catches /USERS/Shared and /USERS/Guest case
        // variants (Mole's explicit parent -ef /Users check).
        let parent = (normalizedPath as NSString).deletingLastPathComponent
        let parentPath = parent.isEmpty ? "/" : parent
        if let parentID = FileIdentity.read(path: parentPath),
           FileIdentity.read(path: "/Users") == parentID {
            return true
        }

        return false
    }

    // MARK: - Mapping

    /// SafetyGate's string reasons map 1:1 onto the public Reason set.
    private static func map(_ reason: SafetyGate.RejectionReason) -> Reason {
        switch reason {
        case .emptyPath: return .emptyPath
        case .relativePath: return .relativePath
        case .pathTraversal: return .pathTraversal
        case .controlCharacters: return .controlCharacters
        case .whitelisted: return .whitelisted
        case .criticalSystemPath: return .criticalSystemPath
        case .appleSystemFragment: return .appleSystemFragment
        }
    }
}
