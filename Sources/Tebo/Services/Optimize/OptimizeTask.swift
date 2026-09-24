import Foundation

// MARK: - OptimizeTask
// Typed port of Mole's optimize catalog (mole-src lib/optimize/catalog.sh). Mole keeps the catalog
// in aligned bash arrays; here every row is one immutable struct the Health tab can render directly.
// Fields mirror Mole's registration: action id, health name (title), description (explanation),
// plus the exact command (steps), the admin requirement, a risk rating and the upstream citation.
// Hard rules carried over from Mole's AGENTS.md: ported tasks never delete user files and never
// touch the live PowerLog database. Tasks that delete anything stay in DeletePipeline's domain.

/// How risky a task is, shown as a badge in the Health tab.
/// Mirrors the risk levels Mole tags in its debug output (e.g. debug_risk_level "MEDIUM").
public enum OptimizeRisk: String, Sendable, Equatable, CaseIterable {
    case low
    case medium
    case high
}

/// One executable invocation inside a task. The executable is always an absolute path to a real
/// binary — never a shell, never a PATH lookup — and the arguments are handed to execve verbatim,
/// so shell metacharacters can never be interpreted (Mole AGENTS.md: resolve binaries by
/// absolute path, do not shell out to bash).
public struct OptimizeCommandStep: Sendable, Equatable, Hashable {
    /// Absolute path, e.g. "/usr/sbin/dscacheutil".
    public let executable: String
    /// Arguments in execve order, e.g. ["-flushcache"].
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Human-readable form, used for the "run this yourself" hint on admin tasks.
    public var display: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// One catalog entry. Immutable: the catalog is data, the runner only reads it.
public struct OptimizeTask: Sendable, Equatable, Identifiable {
    /// Stable action name, e.g. "cache_refresh" (Mole's MOLE_OPTIMIZE_ACTIONS entry).
    public let id: String
    /// User-facing title (Mole's health name), e.g. "Finder Cache Refresh".
    public let title: String
    /// What the task actually does and why it is safe — or why it needs admin.
    public let explanation: String
    /// Display section for the Health tab (Mole has no grouping; Tebo adds one for the UI).
    public let group: String
    /// The exact commands executed, in order. One task, one child process per step.
    public let steps: [OptimizeCommandStep]
    /// True when Mole runs this task under sudo. The runner refuses these unless the app
    /// itself is already root — see OptimizeRunner.
    public let needsAdmin: Bool
    /// Risk badge for the UI.
    public let risk: OptimizeRisk
    /// Upstream provenance as file:line ranges, e.g. "lib/optimize/catalog.sh:34-36".

    public let citation: String

    public init(
        id: String,
        title: String,
        explanation: String,
        group: String,
        steps: [OptimizeCommandStep],
        needsAdmin: Bool,
        risk: OptimizeRisk,
        citation: String
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.group = group
        self.steps = steps
        self.needsAdmin = needsAdmin
        self.risk = risk
        self.citation = citation
    }

    /// One display line per command, for the "run it yourself in Terminal" hint.
    public var commandLines: [String] {
        steps.map(\.display)
    }
}

/// A task plus its live availability, as returned by the catalog query API.
public struct OptimizeTaskListing: Sendable, Equatable, Identifiable {
    public let task: OptimizeTask
    /// Live flag: every binary the task needs exists and is executable on this Mac right now.
    public let isAvailable: Bool

    public init(task: OptimizeTask, isAvailable: Bool) {
        self.task = task
        self.isAvailable = isAvailable
    }

    public var id: String { task.id }
}

/// Display section for the Health tab: a name plus the tasks that belong to it.
public struct OptimizeTaskGroup: Sendable, Equatable {
    public let name: String
    public let items: [OptimizeTaskListing]

    public init(name: String, items: [OptimizeTaskListing]) {
        self.name = name
        self.items = items
    }
}
