import Foundation

// MARK: - Mole cleanup target model
// Typed, dependency-free model of tw93/Mole's cleanup knowledge (GPL-3.0).
// The tables under Services/MoleTables/ hold DATA only: no disk access, no
// scanning, no deletion. A later engine consumes [CleanTarget] and resolves
// paths through MolePathResolver.

// MARK: Risk

/// Whether removing a target is safe by default or needs user review.
public enum MoleRisk: String, Sendable, Equatable {
    /// Rebuildable caches/logs — the owning app recreates them on demand.
    case safe
    /// Real user data — never delete without the user confirming.
    case review
}

// MARK: Group

/// The Mole cleanup section a target belongs to (mirrors `mo clean` sections).
public enum MoleGroup: String, Sendable, Equatable, CaseIterable {
    case userEssentials = "User Essentials"
    case appCaches = "App Caches"
    case browsers = "Browsers"
    case guiApps = "GUI Apps"
}

// MARK: Path

/// Where a target lives. Home-relative paths are resolved against the current
/// user's home by MolePathResolver; absolute paths are fixed locations such as
/// /Applications.
public enum MolePath: Sendable, Equatable {
    /// Relative to the user's home directory (e.g. "Library/Caches").
    case homeRelative(String)
    /// Fixed absolute path (e.g. "/Applications/Google Chrome.app").
    case absolute(String)
}

// MARK: Kind

/// How the engine turns a target into concrete deletion candidates.
public enum MoleTargetKind: Sendable, Equatable {
    /// Remove the directory's direct children (bash: safe_clean "$dir"/*).
    case directorySweep
    /// Remove the directory itself (bash: safe_clean "$dir").
    case directory
    /// Remove this exact file.
    case file
    /// Expand the wildcard pattern; matches may be files or directories.
    case glob
    /// Chromium-style app bundle: remove old children of
    /// `<app>/Contents/Frameworks/<framework>/Versions` per MolePruneRule.
    case frameworkVersions(framework: String)
    /// Recursive find with depth and mtime-age filters (bash find -mtime/-mmin).
    case findRule(maxDepth: Int?, minAgeMinutes: Int, filesOnly: Bool)
}

// MARK: Prune rule

/// Selection rule for rows that remove a subset of sibling directories.
public enum MolePruneRule: Sendable, Equatable {
    /// Keep the version dir the `Current` symlink points at, plus any newer
    /// staged auto-update (Chromium framework layout).
    case keepCurrentSymlinkTarget
    /// Keep payloads not strictly older than the installed app version
    /// (Edge updater — no Current symlink exists there).
    case keepInstalledOrNewerVersion
    /// Only numbered dirs whose `seg.x0` is older than N days are removed
    /// (NeatDM incomplete download segments).
    case staleNumberedSegments(minAgeDays: Int)
}

// MARK: Process guard

/// An app/process that must NOT be running while this target is cleaned.
/// Mirrors Mole's pgrep probes: `family` is the deferred-skip label reported
/// to the user, `exactProcessNames` are the pgrep -x probes, and
/// `pathSubstrings` are the pgrep -f bundle-path probes.
public struct MoleProcessGuard: Sendable, Equatable {
    public let family: String
    public let exactProcessNames: [String]
    public let pathSubstrings: [String]

    public init(
        family: String,
        exactProcessNames: [String] = [],
        pathSubstrings: [String] = []
    ) {
        self.family = family
        self.exactProcessNames = exactProcessNames
        self.pathSubstrings = pathSubstrings
    }

    /// Common case: one exact process name, same as the family label.
    public static func exact(_ name: String) -> MoleProcessGuard {
        MoleProcessGuard(family: name, exactProcessNames: [name])
    }
}

// MARK: CleanTarget

/// One cleanup row ported from Mole's bash tables.
public struct CleanTarget: Sendable, Equatable {
    /// User-facing row title, e.g. "Chrome profile cache".
    public let label: String
    /// The Mole section this row belongs to.
    public let group: MoleGroup
    /// Where the target lives (home-relative or absolute).
    public let path: MolePath
    /// How the engine turns the path into deletion candidates.
    public let kind: MoleTargetKind
    /// Safe to clean by default, or needs user review first.
    public let risk: MoleRisk
    /// True when removal needs elevated permissions.
    public let needsAdmin: Bool
    /// Why the data is rebuildable / what it is, in user-facing words.
    public let explanation: String
    /// App/process that must not be running while cleaning; nil = no guard.
    public let processGuard: MoleProcessGuard?
    /// Subset-selection rule (browser old versions, stale segments).
    public let pruneRule: MolePruneRule?
    /// Report-only rows are shown for review but never deleted (e.g. Trash).
    public let reportOnly: Bool
    /// Upstream citation, e.g. "mole lib/clean/user.sh:1695".
    public let source: String

    public init(
        label: String,
        group: MoleGroup,
        path: MolePath,
        kind: MoleTargetKind,
        risk: MoleRisk = .safe,
        needsAdmin: Bool = false,
        explanation: String,
        processGuard: MoleProcessGuard? = nil,
        pruneRule: MolePruneRule? = nil,
        reportOnly: Bool = false,
        source: String
    ) {
        self.label = label
        self.group = group
        self.path = path
        self.kind = kind
        self.risk = risk
        self.needsAdmin = needsAdmin
        self.explanation = explanation
        self.processGuard = processGuard
        self.pruneRule = pruneRule
        self.reportOnly = reportOnly
        self.source = source
    }
}

// MARK: Resolver

/// Expands a MolePath against a home directory. No disk access; wildcards are
/// preserved so glob rows stay engine-expandable.
public enum MolePathResolver {
    /// Resolve against an explicit home path (pure, no IO).
    public static func resolve(_ path: MolePath, home: String) -> String {
        switch path {
        case .homeRelative(let relative):
            return (home as NSString).appendingPathComponent(relative)
        case .absolute(let absolute):
            return absolute
        }
    }

    /// Resolve against the current user's home (FileManager lookup, no IO).
    public static func resolve(_ path: MolePath) -> String {
        resolve(path, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

// MARK: All tables

/// Aggregate of every ported Mole table. The engine consumes this directly.
public enum MoleTables {
    public static var allTargets: [CleanTarget] {
        UserEssentials.all + AppCaches.all + Browsers.all + GuiApps.all
    }
}
