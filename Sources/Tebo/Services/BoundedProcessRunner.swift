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

public enum BoundedProcessRunner {
    public struct Result: Sendable {
        let terminationStatus: Int32?  // nil = launch failed
        let stdout: String
        let stderr: String
        var outputTruncated = false
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false
        func drain(_ handle: FileHandle) {
            while true {
                guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
                lock.lock()
                let room = max(0, 4_194_304 - data.count)
                data.append(chunk.prefix(room))
                if chunk.count > room { truncated = true }
                lock.unlock()
            }
        }
        func snapshot() -> (String, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (String(data: data, encoding: .utf8) ?? "", truncated)
        }
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
        guard !Task.isCancelled else { return Result(terminationStatus: nil, stdout: "", stderr: "Cancelled") }
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
        let output = OutputBuffer(), errorOutput = OutputBuffer()
        let readers = DispatchGroup()
        readers.enter(); readers.enter()
        DispatchQueue.global(qos: .utility).async {
            output.drain(stdoutPipe.fileHandleForReading); readers.leave()
        }
        DispatchQueue.global(qos: .utility).async {
            errorOutput.drain(stderrPipe.fileHandleForReading); readers.leave()
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                process.terminationHandler = { proc in
                    // Runs on an internal queue after the child is reaped, so EOF on both pipes is
                    // guaranteed (the child's write ends are closed).
                    readers.notify(queue: .global(qos: .utility)) {
                        guard let result = state.resumeOnce({
                            let out = output.snapshot(), err = errorOutput.snapshot()
                            return Result(terminationStatus: proc.terminationStatus, stdout: out.0,
                                          stderr: err.0, outputTruncated: out.1 || err.1)
                        }) else { return }
                        continuation.resume(returning: result)
                    }
                }
                do {
                    try process.run()
                    if Task.isCancelled { hardKill(process) }
                } catch {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
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
