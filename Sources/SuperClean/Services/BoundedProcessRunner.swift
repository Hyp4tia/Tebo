import Darwin
import Foundation

// MARK: - BoundedProcessRunner
// The one place this app spawns a child process. Used by the czkawka engine, tmutil in
// TimeMachineSnapshots and mdfind in OrphanScanner.
//
// WHY NOT Process.waitUntilExit: after terminate() the blocking wait can miss the child's exit
// event and block forever (observed on this machine: a probe sat 23 minutes at 0% CPU). Exit
// delivery goes through terminationHandler instead, which Foundation reaps reliably. A child that
// ignores SIGTERM gets SIGKILL after a short grace period, mirroring Mole's run_with_timeout.
//
// timeout nil means no deadline: an engine scan of a large tree legitimately runs for minutes and
// the user can cancel it. Every bounded call site passes a value.

enum BoundedProcessRunner {
    struct Result {
        let terminationStatus: Int32?  // nil = launch failed
        let stdout: String
        let stderr: String
    }

    /// Single-shot resume guard for the exit handler (which can race the launch-failure path).
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func resumeOnce<T>(_ make: () -> T) -> T? {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return nil }
            resumed = true
            return make()
        }
    }

    static func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval?,
        environment: [String: String]? = nil
    ) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment { process.environment = environment }

        // Closed stdin: a task must never sit waiting for input nobody will type.
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let state = RunState()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                process.terminationHandler = { proc in
                    // Runs on an internal queue after the child is reaped, so EOF on both pipes is
                    // guaranteed (the child's write ends are closed).
                    guard let result = state.resumeOnce({
                        let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        return Result(terminationStatus: proc.terminationStatus, stdout: out, stderr: err)
                    }) else { return }
                    continuation.resume(returning: result)
                }
                do {
                    try process.run()
                } catch {
                    guard let result = state.resumeOnce({
                        Result(terminationStatus: nil, stdout: "", stderr: "")
                    }) else { return }
                    continuation.resume(returning: result)
                    return
                }
                // Drop the parent's copy of the write ends so the EOF reads above cannot wait on
                // our own descriptors.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                if let timeout { armWatchdog(for: process, timeout: timeout) }
            }
        } onCancel: {
            // Cancellation must never leave a live child behind the caller's back.
            hardKill(process)
        }
    }

    private static func armWatchdog(for process: Process, timeout: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                guard process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private static func hardKill(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
