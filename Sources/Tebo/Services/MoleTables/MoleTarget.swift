import Foundation

// MARK: - Mole cleanup target model
// Typed, dependency-free model of tw93/Mole's cleanup knowledge (GPL-3.0).
// The tables under Services/MoleTables/ hold DATA only: no disk access, no
// scanning, no deletion. A later engine consumes [CleanTarget] and resolves
// paths through MolePathResolver.

// MARK: Risk

/// Whether removing a target is safe by default or needs user review first.
public enum MoleRisk: String, Sendable, Equatable {
    /// Rebuildable caches/logs — the owning app recreates them on demand.
    case safe
    /// Real user data — never delete without the user confirming.
    case review
}

/// Whether the current scanner implements enough source-reviewed behavior to
/// expose a target for selection. Risk is descriptive; eligibility is the gate.
public enum MoleEligibility: String, Sendable, Equatable, CaseIterable {
    /// No complete, reviewed deletion contract exists. The target is read-only.
    case unsupported
    /// A narrowly scoped, rebuildable cache with tested positive and negative guards.
    case rebuildableCache
    /// A narrowly scoped candidate may be shown for explicit user review, never recommended.
    case manualReview
}

// MARK: Group

/// The Mole cleanup section a target belongs to (mirrors `mo clean` sections).
public enum MoleGroup: String, Sendable, Equatable, CaseIterable {
    case userEssentials = "User Essentials"
    case appCaches = "App Caches"
    case browsers = "Browsers"
    case guiApps = "GUI Apps"
    case developerTools = "Developer Tools"
    case cloudOffice = "Cloud & Office"
    case systemPaths = "System Paths"
    case virtualization = "Virtualization"
    case firmware = "Firmware"
    case timeMachine = "Time Machine"
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
    /// Root of user-owned Group Containers. Scans only direct files under
    /// approved Logs/Caches subdirectories; never returns a container root.
    case groupContainerLeaves
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
    /// Keep the `keepCount` most-recent siblings (by mtime) and remove the
    /// rest (Xcode DeviceSupport versions, Xcode documentation indexes).
    case keepNewest(keepCount: Int)
}

// MARK: Scan budget

/// Per-rule work ceilings for measurement walks and activity probes.
/// A cap, not a target: small items finish as fast as before; only genuinely
/// huge tool caches use the upper bound, and everything stays cancellable.
public struct MoleScanBudget: Sendable, Equatable {
    public let entryLimit: Int
    public let measurementTimeout: TimeInterval
    public let activityProbeTimeout: TimeInterval

    public init(entryLimit: Int, measurementTimeout: TimeInterval, activityProbeTimeout: TimeInterval) {
        self.entryLimit = entryLimit
        self.measurementTimeout = measurementTimeout
        self.activityProbeTimeout = activityProbeTimeout
    }

    /// The historical strict default: small, tightly bounded walks.
    public static let standard = MoleScanBudget(entryLimit: 50_000, measurementTimeout: 4, activityProbeTimeout: 3)
    /// Multi-GB tool-generated caches (Xcode DerivedData, DeviceSupport, simulator
    /// and package-manager caches). 1M entries matches the largest measured trees.
    public static let bulk = MoleScanBudget(entryLimit: 1_000_000, measurementTimeout: 90, activityProbeTimeout: 30)
}

// MARK: Evidence policy

/// Which safety-evidence classes a reviewed rule may tolerate.
/// `.strict` keeps every item carrying repository, credential or symlink evidence.
/// Tool-generated cache families opt in to the narrow tolerances their real
/// content requires, each with positive and negative regression coverage.
public struct MoleEvidencePolicy: Sendable, Equatable {
    /// Symlinks whose targets resolve inside the rule root are tool-internal.
    /// Deleting the item removes the link, never the target; escapes stay blocking.
    public let toleratesRootContainedSymlinks: Bool
    /// Repository markers below one of these path fragments are dependency
    /// checkouts (re-fetched on next resolve), not user repositories.
    public let toleratedRepositoryFragments: [String]
    /// Exact lowercased file names that are build-product payloads, not credentials.
    public let toleratedCredentialNames: [String]

    public init(toleratesRootContainedSymlinks: Bool = false,
                toleratedRepositoryFragments: [String] = [],
                toleratedCredentialNames: [String] = []) {
        self.toleratesRootContainedSymlinks = toleratesRootContainedSymlinks
        self.toleratedRepositoryFragments = toleratedRepositoryFragments
        self.toleratedCredentialNames = toleratedCredentialNames
    }

    /// Current behavior: every evidence class blocks.
    public static let strict = MoleEvidencePolicy()
    /// Package-manager and simulator caches: internal links are expected.
    public static let developerCache = MoleEvidencePolicy(toleratesRootContainedSymlinks: true)
    /// Xcode build caches: SwiftPM dependency checkouts and embedded provisioning
    /// payloads are build outputs, not user state.
    public static let xcodeBuildCache = MoleEvidencePolicy(
        toleratesRootContainedSymlinks: true,
        toleratedRepositoryFragments: ["/SourcePackages/checkouts/"],
        toleratedCredentialNames: ["embedded.mobileprovision"])
}

// MARK: Rule contract

/// The resolved scan contract of one rule: the work ceiling, the evidence
/// tolerances and the literal root that tolerated symlinks must stay inside.
/// Discovery and removal resolve the same values from the same target, so a
/// row that passed the scan boundary revalidates against identical terms.
/// Pure layout math, usable from the removal sink without owning a scanner.
public struct MoleRuleContract: Sendable, Equatable {
    public let budget: MoleScanBudget
    public let evidencePolicy: MoleEvidencePolicy
    public let containmentRoot: String?

    public init(budget: MoleScanBudget, evidencePolicy: MoleEvidencePolicy, containmentRoot: String?) {
        self.budget = budget
        self.evidencePolicy = evidencePolicy
        self.containmentRoot = containmentRoot
    }
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
    /// True for guard families Mole brackets around a
    /// `simctl list devices booted -j` probe (simulator-owned data).
    public let probesBootedSimulator: Bool

    public init(
        family: String,
        exactProcessNames: [String] = [],
        pathSubstrings: [String] = [],
        probesBootedSimulator: Bool = false
    ) {
        self.family = family
        self.exactProcessNames = exactProcessNames
        self.pathSubstrings = pathSubstrings
        self.probesBootedSimulator = probesBootedSimulator
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
    /// Safe to clean by default or needs user review first.
    public let risk: MoleRisk
    /// Explicit source-reviewed eligibility gate; unsupported targets are read-only.
    public let eligibility: MoleEligibility
    /// True when removal needs elevated permissions.
    public let needsAdmin: Bool
    /// Why the data is rebuildable / what it is, in user-facing words.
    public let explanation: String
    /// App/process that must not be running while cleaning; nil = no guard.
    public let processGuard: MoleProcessGuard?
    /// Subset-selection rule (browser old versions, stale segments).
    public let pruneRule: MolePruneRule?
    /// Per-rule work ceiling for measurement walks and activity probes.
    public let scanBudget: MoleScanBudget
    /// Which safety-evidence classes this reviewed rule may tolerate.
    public let evidencePolicy: MoleEvidencePolicy
    /// Report-only rows are shown for review but never deleted (e.g. Trash).
    public let reportOnly: Bool
    /// Upstream citation, e.g. "mole lib/clean/user.sh:1695".
    public let source: String

    public init(
        label: String,
        group: MoleGroup,
        path: MolePath,
        kind: MoleTargetKind,
        risk: MoleRisk = .review,
        eligibility: MoleEligibility = .unsupported,
        needsAdmin: Bool = false,
        explanation: String,
        processGuard: MoleProcessGuard? = nil,
        pruneRule: MolePruneRule? = nil,
        scanBudget: MoleScanBudget = .standard,
        evidencePolicy: MoleEvidencePolicy = .strict,
        reportOnly: Bool = false,
        source: String
    ) {
        self.label = label
        self.group = group
        self.path = path
        self.kind = kind
        self.risk = risk
        self.eligibility = eligibility
        self.needsAdmin = needsAdmin
        self.explanation = explanation
        self.processGuard = processGuard
        self.pruneRule = pruneRule
        self.scanBudget = scanBudget
        self.evidencePolicy = evidencePolicy
        self.reportOnly = reportOnly
        self.source = source
    }

    /// Stable identity for manifests, scan provenance, and final rule reevaluation.
    /// It depends only on rule-defining data, never on the current home or file system.
    public var ruleID: String {
        let pathIdentity: String
        switch path {
        case .homeRelative(let value): pathIdentity = "home:\(value)"
        case .absolute(let value): pathIdentity = "absolute:\(value)"
        }
        let kindIdentity: String
        switch kind {
        case .directorySweep: kindIdentity = "directory-sweep"
        case .directory: kindIdentity = "directory"
        case .file: kindIdentity = "file"
        case .glob: kindIdentity = "glob"
        case .groupContainerLeaves: kindIdentity = "group-container-leaves"
        case .frameworkVersions(let framework): kindIdentity = "framework-versions:\(framework)"
        case .findRule(let maxDepth, let age, let filesOnly):
            kindIdentity = "find:\(maxDepth.map(String.init) ?? "default"):\(age):\(filesOnly)"
        }
        let pruneIdentity: String
        switch pruneRule {
        case nil: pruneIdentity = "none"
        case .keepCurrentSymlinkTarget: pruneIdentity = "keep-current-and-newer-staged"
        case .keepInstalledOrNewerVersion: pruneIdentity = "keep-installed-or-newer"
        case .staleNumberedSegments(let days): pruneIdentity = "stale-segments:\(days)"
        case .keepNewest(let count): pruneIdentity = "keep-newest:\(count)"
        }
        let processIdentity = processGuard.map {
            "\($0.family)|\($0.exactProcessNames.sorted().joined(separator: ","))|\($0.pathSubstrings.sorted().joined(separator: ","))"
        } ?? "unguarded"
        let bootedSuffix = processGuard?.probesBootedSimulator == true ? "|booted" : ""
        let sourceIdentity = source.range(of: #":[0-9]+$"#, options: .regularExpression)
            .map { String(source[..<$0.lowerBound]) } ?? source
        let components = [group.rawValue, label, pathIdentity, kindIdentity, pruneIdentity, processIdentity + bootedSuffix, sourceIdentity]
        return "mole:" + components.map(Self.ruleIDComponent).joined(separator: ":")
    }

    private static func ruleIDComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) { return encoded }
        return Data(value.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
    }

    /// Budget, policy and literal root resolved together. The scan boundary and
    /// the removal boundary both go through this, so they never disagree.
    public func contract(home: String = NSHomeDirectory()) -> MoleRuleContract {
        MoleRuleContract(budget: scanBudget, evidencePolicy: evidencePolicy,
                         containmentRoot: Self.containmentRoot(for: path, home: home))
    }

    /// Literal prefix of the rule path before its first wildcard component:
    /// the root a tolerated symlink's target must stay inside. nil when the
    /// prefix cannot contain anything (wildcard first, or the filesystem root).
    public static func containmentRoot(for path: MolePath, home: String) -> String? {
        let resolved = MolePathResolver.resolve(path, home: home)
        let components = resolved.split(separator: "/").map(String.init)
        if let firstPattern = components.firstIndex(where: {
            $0.contains("*") || $0.contains("?") || $0.contains("[")
        }) {
            guard firstPattern > 0 else { return nil }
            let normalized = SafetyGate.normalized("/" + components.prefix(firstPattern).joined(separator: "/"))
            return normalized == "/" ? nil : normalized
        }
        let normalized = SafetyGate.normalized(resolved)
        return normalized == "/" ? nil : normalized
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
            + DeveloperTools.all + CloudOffice.all + SystemPaths.all
            + Virtualization.all + Firmware.all + TimeMachine.all
    }
}
