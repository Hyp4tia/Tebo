import Darwin
import Foundation
import Testing
@testable import SuperClean

// MARK: - Optimize tests
// Catalog integrity + runner behavior. Runner tests use real system binaries (/usr/bin/true,
// /bin/echo, /bin/ls, /bin/sleep) but never root-requiring commands and never write to the real
// OperationLog (recordLine is always injected). No task here deletes anything.

@Suite("Optimize")
struct OptimizeTests {

    /// Binary names that must never appear as a task executable: shells, privilege escalators
    /// and file-deletion tools.
    private let bannedExecutables: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish",
        "sudo", "env", "xargs", "python", "python3", "perl", "ruby",
        "rm", "rmdir", "mv", "cp", "dd", "trash", "delete",
    ]

    /// Characters a shell would interpret. Arguments must contain none of them, so a task's
    /// command is inert even if it were ever concatenated into a shell string.
    private let shellMetacharacters: Set<Character> = Set("|&;<>()$`\\\"'*?~!#[]{} \n\t")

    private func makeTask(
        id: String = "probe",
        executable: String,
        arguments: [String] = [],
        needsAdmin: Bool = false
    ) -> OptimizeTask {
        OptimizeTask(
            id: id,
            title: "Probe",
            explanation: "Test task",
            group: "Probe",
            steps: [OptimizeCommandStep(executable: executable, arguments: arguments)],
            needsAdmin: needsAdmin,
            risk: .low,
            citation: "test"
        )
    }

    /// Capture box for the runner's recordLine injection (never touches the real log file).
    private actor LineBox {
        private(set) var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
    }

    // MARK: Catalog integrity

    @Test("Catalog has unique task ids")
    func uniqueIDs() {
        let ids = OptimizeCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.isEmpty)
    }

    @Test("Every task carries title, explanation and upstream citation")
    func completeMetadata() {
        for task in OptimizeCatalog.all {
            #expect(!task.title.isEmpty, "\(task.id) has no title")
            #expect(!task.explanation.isEmpty, "\(task.id) has no explanation")
            #expect(!task.citation.isEmpty, "\(task.id) has no citation")
            #expect(task.citation.contains("lib/optimize/"), "\(task.id) citation lacks upstream path")
            #expect(!task.steps.isEmpty, "\(task.id) has no command")
        }
    }

    @Test("No command uses a shell or shell metacharacters")
    func noShellInCommands() {
        for task in OptimizeCatalog.all {
            for step in task.steps {
                let name = URL(fileURLWithPath: step.executable).lastPathComponent
                #expect(
                    step.executable.hasPrefix("/"),
                    "\(task.id): executable is not an absolute path: \(step.executable)"
                )
                #expect(
                    !bannedExecutables.contains(name),
                    "\(task.id): shell/escalation/delete binary not allowed: \(name)"
                )
                for argument in step.arguments {
                    for character in argument {
                        #expect(
                            !shellMetacharacters.contains(character),
                            "\(task.id): shell metacharacter in argument: \(argument)"
                        )
                    }
                }
            }
        }
    }

    @Test("No task deletes files or touches the PowerLog database")
    func noDeletionNoPowerLog() {
        for task in OptimizeCatalog.all {
            for step in task.steps {
                let whole = (step.executable + " " + step.arguments.joined(separator: " "))
                    .lowercased()
                #expect(!whole.contains("powerlog"), "\(task.id) references the PowerLog database")
                #expect(!step.arguments.contains("-delete"), "\(task.id) uses find -delete")
            }
        }
    }

    @Test("Admin flag matches the upstream catalog")
    func adminClassification() {
        #expect(OptimizeCatalog.all.count == 8)
        let admin = Set(OptimizeCatalog.all.filter(\.needsAdmin).map(\.id))
        #expect(admin == [
            "system_maintenance", "network_optimization", "network_stack_optimize",
            "disk_permissions_repair", "spotlight_index_optimize", "periodic_maintenance",
        ])
        let userLevel = Set(OptimizeCatalog.all.filter { !$0.needsAdmin }.map(\.id))
        #expect(userLevel == ["cache_refresh", "prevent_network_dsstore"])
    }

    // MARK: Catalog query API

    @Test("Grouped query exposes live availability and admin flags")
    func groupedQuery() {
        let groups = OptimizeCatalog.groups()
        #expect(groups.map(\.name) == ["Network", "Finder", "System", "Maintenance"])
        let listings = groups.flatMap(\.items)
        // Every task appears exactly once. Grouping legitimately reorders sections, so compare
        // as sets (catalog order is preserved inside each group).
        #expect(listings.count == OptimizeCatalog.all.count)
        #expect(Set(listings.map(\.task.id)) == Set(OptimizeCatalog.all.map(\.id)))
        let byID = Dictionary(uniqueKeysWithValues: OptimizeCatalog.all.map { ($0.id, $0) })
        for listing in listings {
            // The available flag is live: it must agree with the shared check.
            #expect(listing.isAvailable == OptimizeCatalog.isAvailable(listing.task))
            // The admin flag travels with the task and stays consistent with the catalog.
            #expect(listing.task.needsAdmin == (byID[listing.task.id]?.needsAdmin ?? false))
        }
        #expect(OptimizeCatalog.task(id: "cache_refresh") != nil)
        #expect(OptimizeCatalog.task(id: "not_in_catalog") == nil)
    }

    @Test("Availability detects a missing binary")
    func availabilityProbe() {
        let present = makeTask(executable: "/usr/bin/true")
        #expect(OptimizeCatalog.isAvailable(present))
        let missing = makeTask(executable: "/nonexistent/superclean-probe-binary")
        #expect(!OptimizeCatalog.isAvailable(missing))
        let taskWithoutSteps = OptimizeTask(
            id: "no-steps", title: "x", explanation: "x", group: "x", steps: [],
            needsAdmin: false, risk: .low, citation: "test"
        )
        #expect(!OptimizeCatalog.isAvailable(taskWithoutSteps))
    }

    // MARK: Runner behavior

    @Test("Runner skips unavailable binaries without executing")
    func runnerUnavailable() async {
        let task = makeTask(executable: "/nonexistent/superclean-probe-binary")
        let result = await OptimizeRunner().run(task, recordLine: { _ in })
        #expect(result == .skippedUnavailableBinary)
    }

    @Test("Runner skips admin tasks when not running as root")
    func runnerNeedsAdmin() async {
        // The suite runs as the regular user; when it ever runs as root this test is void
        // because the task would legitimately execute.
        guard getuid() != 0 else { return }
        let task = makeTask(executable: "/usr/bin/true", needsAdmin: true)
        let result = await OptimizeRunner().run(task, recordLine: { _ in })
        #expect(result == .skippedNeedsAdmin)
    }

    @Test("Runner succeeds and returns captured output")
    func runnerSucceeds() async {
        let task = makeTask(
            id: "echo", executable: "/bin/echo", arguments: ["superclean-optimize-marker"]
        )
        let result = await OptimizeRunner().run(task, recordLine: { _ in })
        guard case .succeeded(let output) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(output.contains("superclean-optimize-marker"))
    }

    @Test("Runner reports exit code and stderr tail on failure")
    func runnerFails() async {
        let task = makeTask(
            id: "ls", executable: "/bin/ls",
            arguments: ["/definitely-missing-superclean-xyz"]
        )
        let result = await OptimizeRunner().run(task, recordLine: { _ in })
        guard case .failed(let code, let tail) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(code != 0)
        #expect(tail.contains("No such file"))
    }

    @Test("Runner kills a hung child on timeout")
    func runnerTimesOut() async {
        let task = makeTask(id: "sleep", executable: "/bin/sleep", arguments: ["5"])
        let result = await OptimizeRunner().run(task, timeout: 0.5, recordLine: { _ in })
        #expect(result == .timedOut)
    }

    @Test("Runner records start and outcome lines")
    func runnerLogs() async {
        let box = LineBox()
        let task = makeTask(id: "echo", executable: "/bin/echo", arguments: ["logged"])
        _ = await OptimizeRunner().run(task, recordLine: { line in await box.add(line) })
        let lines = await box.lines
        #expect(lines.contains { $0.hasPrefix("Optimize echo: started") })
        #expect(lines.contains { $0.hasPrefix("Optimize echo: succeeded") })
    }
}
