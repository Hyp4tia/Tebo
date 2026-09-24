import Foundation

// MARK: - DeletePipeline
// The ONLY code path in the app allowed to call FileManager.trashItem.
// Ports Mole's safe_remove pipeline (lib/core/file_ops.sh): validate, bind
// the file's identity, re-verify right before the move, and fail closed on
// every mismatch. A rename-and-recreate race can never turn an approved
// path into permission to trash the file that replaced it.

// MARK: - SkipReason

/// Why one path was skipped. Typed so the UI renders a stable string.
public enum SkipReason: Sendable, Equatable {
    case invalidPath(PathValidator.Reason)
    case missing
    case identityChanged

    /// Human-readable line for the report UI.
    public var displayText: String {
        switch self {
        case .invalidPath(let reason): return "blocked: \(reason.rawValue)"
        case .missing: return "file no longer exists"
        case .identityChanged: return "file changed during delete"
        }
    }
}

// MARK: - DeleteReport

/// Result of one trash batch. Sendable + Equatable so views and tests can
/// inspect it across actors.
public struct DeleteReport: Sendable, Equatable {

    /// One input path and what happened to it.
    public struct Outcome: Sendable, Equatable, Identifiable {
        public enum Result: Sendable, Equatable {
            case trashed(bytes: Int64)
            case skipped(reason: SkipReason)
            case failed(message: String)
        }

        public let path: String
        public let result: Result

        public var id: String { path } // Paths are unique within one batch.

        public init(path: String, result: Result) {
            self.path = path
            self.result = result
        }
    }

    /// Ordered outcomes, one per input path.
    public let outcomes: [Outcome]

    public init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    // MARK: Derived totals (what the UI footer shows)

    /// Bytes actually reclaimed (sum of trashed item sizes).
    public var freedBytes: Int64 {
        outcomes.reduce(0) { total, outcome in
            if case .trashed(let bytes) = outcome.result { return total + bytes }
            return total
        }
    }

    public var trashedCount: Int {
        outcomes.count { if case .trashed = $0.result { return true }; return false }
    }

    public var skippedCount: Int {
        outcomes.count { if case .skipped = $0.result { return true }; return false }
    }

    public var failedCount: Int {
        outcomes.count { if case .failed = $0.result { return true }; return false }
    }

    /// One-line summary, e.g. "Trashed 3 items (1.2 GB), skipped 2, 1 failed".
    public var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)
        return "Trashed \(trashedCount) items (\(size)), "
            + "skipped \(skippedCount), failed \(failedCount)"
    }
}

// MARK: - DeletePipeline

/// Stateless delete sink. The single choke point for FileManager.trashItem.
public struct DeletePipeline: Sendable {

    public init() {}

    // MARK: - Public API

    /// Validate and move `paths` to Trash, one at a time, fail closed.
    /// - Parameters:
    ///   - paths: Absolute paths selected by the user.
    ///   - whitelist: User-protected substrings (same semantics as SafetyGate).
    ///   - beforeMove: instrumentation hook awaited immediately before the
    ///     final identity check and the move. Production callers pass nil;
    ///     tests use it to simulate a file being swapped mid-run.
    public func trash(
        paths: [String],
        whitelist: Set<String>,
        beforeMove: (@Sendable (String) async -> Void)? = nil
    ) async -> DeleteReport {
        var outcomes: [DeleteReport.Outcome] = []
        outcomes.reserveCapacity(paths.count)
        for path in paths {
            if Task.isCancelled { break }
            outcomes.append(
                await trashOne(path: path, whitelist: whitelist, beforeMove: beforeMove)
            )
        }
        return DeleteReport(outcomes: outcomes)
    }

    // MARK: - Per-path pipeline (mirrors safe_remove's final sink)

    private func trashOne(
        path: String,
        whitelist: Set<String>,
        beforeMove: (@Sendable (String) async -> Void)?
    ) async -> DeleteReport.Outcome {
        // 1. Gate: string rules + symlink resolution + inode guards.
        if let reason = PathValidator.validate(path: path, whitelist: whitelist) {
            await OperationLog.shared.record("Skipped \(path): \(reason.rawValue)")
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .invalidPath(reason)))
        }

        // 2. Bind the file's identity before any other work.
        guard let bound = FileIdentity.read(path: path) else {
            await OperationLog.shared.record("Skipped \(path): file no longer exists")
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .missing))
        }

        // 3. Measure for the report. This is the expensive window: the file
        //    can be swapped while the size walk runs, hence the recheck.
        let bytes = CleanerService().recursiveSize(at: path)

        // 4. Re-validate: the object under the path must still be the SAME one.
        guard let current = FileIdentity.read(path: path), current == bound else {
            await OperationLog.shared.record("Skipped \(path): identity changed during delete")
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .identityChanged))
        }

        await beforeMove?(path)

        // 5. Final identity check immediately before the move. An unavoidable
        //    microsecond window remains (Mole notes the same); this recheck
        //    shrinks it to one stat before trashItem.
        guard let final = FileIdentity.read(path: path), final == bound else {
            await OperationLog.shared.record("Skipped \(path): identity changed before move")
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .identityChanged))
        }

        // 6. The move itself. No other code in the app may call trashItem.
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: path),
                resultingItemURL: &trashed
            )
            await OperationLog.shared.record("Trashed \(path) (\(bytes) bytes)")
            return DeleteReport.Outcome(path: path, result: .trashed(bytes: bytes))
        } catch {
            await OperationLog.shared.record("Failed \(path): \(error.localizedDescription)")
            return DeleteReport.Outcome(
                path: path,
                result: .failed(message: error.localizedDescription)
            )
        }
    }
}
