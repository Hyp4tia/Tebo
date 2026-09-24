import Darwin
import Foundation

// MARK: - OptimizeRunner
// Executes one catalog task at a time with a hard timeout, mirroring Mole's bounded, outcome-driven
// optimize dispatch (mole-src lib/optimize/outcomes.sh:11-23, lib/optimize/tasks.sh:2033-2059).
// Safety invariants:
//   * one task per call, one child process per step, steps run sequentially — never in parallel;
//   * binaries are invoked by absolute path (execve), never through a shell;
//   * stdout and stderr are captured; every command has a hard timeout and the child is killed
//     (SIGTERM, then SIGKILL) when it fires;
//   * the child never runs interactively: its stdin is a closed pipe, so any read sees EOF;
//   * every run is recorded in OperationLog (start line + outcome line);
//   * nothing here deletes files — file removal belongs exclusively to DeletePipeline.

/// Typed outcome of one optimize run. Maps onto Mole's outcome vocabulary (outcomes.sh:18-23):
/// applied/unchanged -> succeeded, failed -> failed, skipped/unavailable -> the two skip cases.
public enum OptimizeTaskResult: Sendable, Equatable {
    /// Every step exited 0. `output` is the concatenated stdout.
    case succeeded(output: String)
    /// A step exited non-zero (or could not be spawned). `stderrTail` is the last 500 chars of
    /// that step's stderr so the UI can show the real failure reason.
    case failed(exitCode: Int32, stderrTail: String)
    /// The hard timeout fired and the child was killed.
    case timedOut
    /// The task needs admin and this app is not running as root; the UI shows the user how to
    /// run the command themselves.
    case skippedNeedsAdmin
    /// A binary the task needs is absent on this Mac; detected up front, never attempted.
    case skippedUnavailableBinary
}

/// Runs optimize tasks. Stateless and cheap to recreate; the Health tab creates one per run.
public struct OptimizeRunner: Sendable {

    public init() {}

    /// Runs one task. `recordLine` defaults to the shared OperationLog; tests inject a no-op or
    /// a capture box so they never write to the real log file.
    public func run(
        _ task: OptimizeTask,
        timeout: TimeInterval = 120,
        fileManager: FileManager = .default,
        recordLine: (@Sendable (String) async -> Void)? = nil
    ) async -> OptimizeTaskResult {
        let log = recordLine ?? { await OperationLog.shared.record($0) }
        await log("Optimize \(task.id): started")

        // Requirement: missing binaries are detected up front and reported, never attempted.
        guard OptimizeCatalog.isAvailable(task, fileManager: fileManager) else {
            await log("Optimize \(task.id): skipped — binary unavailable")
            return .skippedUnavailableBinary
        }

        // DELIBERATE v1.0 POLICY: tasks that need root are NEVER escalated from here. No sudo,
        // no Authorization Services prompt — the runner executes an admin task only when the
        // whole app already runs as root (getuid() == 0). In every other case it returns
        // skippedNeedsAdmin so the UI can show the exact command for the user to run themselves.
        // This mirrors Mole's optimize_sudo_available gate (tasks.sh:41-46): without an upfront
        // sudo session, sudo-gated tasks report SKIPPED instead of prompting.
        if task.needsAdmin, getuid() != 0 {
            await log("Optimize \(task.id): skipped — needs admin")
            return .skippedNeedsAdmin
        }

        var combined = ""
        for step in task.steps {
            let outcome = await ProcessExecution(
                executable: step.executable,
                arguments: step.arguments
            ).execute(timeout: timeout)
            switch outcome {
            case .exited(0, let stdout, _):
                if !stdout.isEmpty {
                    combined += (combined.isEmpty ? "" : "\n") + stdout
                }
            case .exited(let code, _, let stderr):
                let tail = String(stderr.suffix(500))
                await log("Optimize \(task.id): failed (exit=\(code)) \(tail)")
                return .failed(exitCode: code, stderrTail: tail)
            case .timedOut:
                await log("Optimize \(task.id): timed out")
                return .timedOut
            case .spawnFailed(let reason):
                await log("Optimize \(task.id): failed (spawn: \(reason))")
                return .failed(exitCode: -1, stderrTail: reason)
            }
        }
        await log("Optimize \(task.id): succeeded")
        return .succeeded(output: combined)
    }
}

// MARK: - One bounded child process

private enum StepOutcome {
    case exited(Int32, stdout: String, stderr: String)
    case timedOut
    case spawnFailed(reason: String)
}

/// Events collected by the task group while one step runs.
private enum StepEvent {
    case exited(Int32, killed: Bool)
    case stdout(Data)
    case stderr(Data)
    case timeout(killed: Bool)
}

/// One child process with captured output and a hard timeout.
/// Marked @unchecked Sendable on purpose: the runner serializes one step at a time, and all
/// mutable process state (isRunning / terminate / kill / terminationContinuation) is guarded by
/// `stateLock`. Exit observation goes through the terminationHandler continuation, so no
/// cooperative thread is ever blocked waiting on the child. Without the annotation the
/// strict-concurrency compiler would reject cross-task access to Process for a pattern that is
/// single-owner by construction.
private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stateLock = NSLock()
    private var killedByTimer = false
    private var terminationContinuation: CheckedContinuation<Int32, Never>?

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Closed-write-end stdin: the child's first read returns EOF, so no task can ever sit
        // waiting for interactive input or a TTY.
        let input = Pipe()
        process.standardInput = input
        try? input.fileHandleForWriting.close()
        // Exit observation via a callback, not a blocking wait: nothing in this runner ever
        // parks a cooperative thread (pool exhaustion would deadlock the whole app under load).
        // The handler and the waiter synchronize through stateLock so the continuation is
        // resumed exactly once, even when a fast child exits before the waiter installs it.
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.stateLock.lock()
            let continuation = self.terminationContinuation
            self.terminationContinuation = nil
            let status = finished.terminationStatus
            self.stateLock.unlock()
            continuation?.resume(returning: status)
        }
    }

    func execute(timeout: TimeInterval) async -> StepOutcome {
        do {
            try process.run()
        } catch {
            return .spawnFailed(reason: error.localizedDescription)
        }

        return await withTaskGroup(of: StepEvent.self) { group in
            // Two async readers drain the pipes. Iterating FileHandle.AsyncBytes cooperates
            // with task cancellation, so a cancelled group can never leave a reader wedged in
            // a blocking read.
            group.addTask { [self] in
                var collected = [UInt8]()
                do {
                    for try await byte in stdoutPipe.fileHandleForReading.bytes {
                        collected.append(byte)
                    }
                } catch {
                    // Cancelled or pipe closed — whatever arrived is what we report.
                }
                return .stdout(Data(collected))
            }
            group.addTask { [self] in
                var collected = [UInt8]()
                do {
                    for try await byte in stderrPipe.fileHandleForReading.bytes {
                        collected.append(byte)
                    }
                } catch {
                    // Cancelled or pipe closed.
                }
                return .stderr(Data(collected))
            }
            group.addTask { [self] in
                // No blocking wait: the exit arrives through the terminationHandler installed
                // in init. The lock dance covers the race where a fast child exits (handler
                // already fired) before this task installs its continuation. Reading wasKilled
                // afterwards means a child the timer terminated is reported as a timeout, not
                // as a failed(exit 15) — the timer sets the flag before it kills.
                let code = await withCheckedContinuation { continuation in
                    stateLock.lock()
                    if process.isRunning {
                        terminationContinuation = continuation
                        stateLock.unlock()
                    } else {
                        let status = process.terminationStatus
                        stateLock.unlock()
                        continuation.resume(returning: status)
                    }
                }
                return .exited(code, killed: wasKilled())
            }
            group.addTask { [self] in
                try? await Task.sleep(for: .seconds(timeout))
                return .timeout(killed: killIfRunning())
            }

            var code: Int32 = -1
            var outData = Data()
            var errData = Data()
            var exited = false
            var gotStdout = false
            var gotStderr = false
            var timedOut = false

            while let event = await group.next() {
                switch event {
                case .exited(let c, let killed):
                    code = c
                    exited = true
                    if killed { timedOut = true }
                case .stdout(let d):
                    outData = d
                    gotStdout = true
                case .stderr(let d):
                    errData = d
                    gotStderr = true
                case .timeout(let killed):
                    if killed { timedOut = true }
                    // killed == false means the child finished just before the budget
                    // elapsed — keep waiting for its exit event and drained pipes.
                }
                if timedOut {
                    // Decision made. cancelAll() is explicit because group scope-exit
                    // cancellation does not interrupt a child sitting in Task.sleep; the
                    // sleeper must be cancelled here or a fast task waits out its budget.
                    group.cancelAll()
                    break
                }
                if exited, gotStdout, gotStderr {
                    group.cancelAll()
                    break
                }
            }

            if timedOut {
                // The timer fired while the child was alive. Make sure it is dead before the
                // runner moves on; SIGKILL cannot be ignored by the child.
                _ = killIfRunning()
                return .timedOut
            }
            return .exited(
                code,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }
    }

    /// SIGTERM, a short grace period, then SIGKILL. Returns true only when the child was still
    /// running and had to be stopped; the flag lets the waiter distinguish a timeout kill from a
    /// coincidental exit (both arrive as a termination status).
    private func killIfRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard process.isRunning else { return false }
        process.terminate() // SIGTERM: the child gets a beat to exit cleanly.
        Thread.sleep(forTimeInterval: 0.3)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        killedByTimer = true
        return true
    }

    /// Whether the timer terminated this child. Locked because the waiter reads it while the
    /// timer task may still be inside killIfRunning.
    private func wasKilled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return killedByTimer
    }
}
