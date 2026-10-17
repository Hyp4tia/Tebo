import Foundation

// MARK: - DeletePipeline
// The ONLY code path in the app allowed to call FileManager.trashItem.
// Ports Mole's safe_remove pipeline (lib/core/file_ops.sh): validate, bind
// the file's identity, re-verify right before the move, and fail closed on
// every observed mismatch. Pathname-based Trash moves still have a small
// non-atomic window after the final checks.

// MARK: - SkipReason

/// Why one path was skipped. Typed so the UI renders a stable string.
public enum SkipReason: Sendable, Equatable {
    case invalidPath(PathValidator.Reason)
    case missing
    case identityChanged
    case cancelled
    case safetyCheck(String)

    /// Human-readable line for the report UI.
    public var displayText: String {
        switch self {
        case .invalidPath(let reason): return "blocked: \(reason.rawValue)"
        case .missing: return "item is missing or unreadable"
        case .identityChanged: return "review evidence changed or is unavailable; rescan"
        case .cancelled: return "cancelled before the move"
        case .safetyCheck(let reason): return "kept: \(reason)"
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

    /// Logical bytes moved to Trash, not measured free-space gain.
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
        expectedIdentities: [String: FileIdentity] = [:],
        expectedBindings: [String: PathBinding] = [:],
        requirePreviewIdentity: Bool = false,
        enforceCleanupSafety: Bool = false,
        protectionURL: URL? = nil,
        additionalValidation: (@Sendable (String) async -> String?)? = nil,
        beforeMove: (@Sendable (String) async -> Void)? = nil,
        /// Per-path rule contract from the row's producing source. The sink
        /// re-measures with the same budget, policy and containment root the
        /// scan used; nil keeps the strict historical defaults.
        ruleContract: (@Sendable (String) -> MoleRuleContract?)? = nil
    ) async -> DeleteReport {
        var outcomes: [DeleteReport.Outcome] = []
        outcomes.reserveCapacity(paths.count)
        for path in paths {
            if Task.isCancelled {
                outcomes.append(.init(path: path, result: .skipped(reason: .cancelled)))
                continue
            }
            let protections = requirePreviewIdentity || enforceCleanupSafety ? WhitelistStore.snapshot(from: protectionURL) : nil
            if let error = protections?.error {
                outcomes.append(.init(path: path, result: .skipped(reason: .safetyCheck(error))))
                continue
            }
            outcomes.append(
                await trashOne(path: path, whitelist: whitelist.union(protections?.entries ?? []),
                    expectedIdentity: expectedIdentities[path], expectedBinding: expectedBindings[path],
                    requirePreviewIdentity: requirePreviewIdentity || enforceCleanupSafety,
                    enforceCleanupSafety: enforceCleanupSafety, protections: protections, protectionURL: protectionURL,
                    additionalValidation: additionalValidation, beforeMove: beforeMove, ruleContract: ruleContract)
            )
        }
        return DeleteReport(outcomes: outcomes)
    }

    // MARK: - Per-path pipeline (mirrors safe_remove's final sink)

    private func trashOne(
        path: String,
        whitelist: Set<String>,
        expectedIdentity: FileIdentity?,
        expectedBinding: PathBinding?,
        requirePreviewIdentity: Bool,
        enforceCleanupSafety: Bool,
        protections: WhitelistStore.Snapshot?,
        protectionURL: URL?,
        additionalValidation: (@Sendable (String) async -> String?)?,
        beforeMove: (@Sendable (String) async -> Void)?,
        ruleContract: (@Sendable (String) -> MoleRuleContract?)?
    ) async -> DeleteReport.Outcome {
        // 1. Gate: string rules + symlink resolution + inode guards.
        if let reason = PathValidator.validate(path: path, whitelist: whitelist) {
            await OperationLog.shared.record("Skipped \(path): \(reason.rawValue)")
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .invalidPath(reason)))
        }

        // 2. Bind the file's identity before any other work.
        if requirePreviewIdentity, expectedIdentity == nil || expectedBinding == nil {
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .identityChanged))
        }
        guard let binding = PathBinding.read(path: path) else {
            await OperationLog.shared.record("Skipped \(path): file no longer exists")
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .missing))
        }
        if let expectedIdentity, binding.leaf != expectedIdentity {
            await OperationLog.shared.record("Skipped \(path): changed since preview")
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .identityChanged))
        }
        if let expectedBinding, binding != expectedBinding {
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .identityChanged))
        }

        // 3. Measure for the report. This is the expensive window: the file
        //    can be swapped while the size walk runs, hence the recheck.
        var bytes = enforceCleanupSafety ? 0 : CleanerService().recursiveSize(at: path)

        // 4. Re-validate: the object under the path must still be the SAME one.
        guard PathBinding.read(path: path) == binding else {
            await OperationLog.shared.record("Skipped \(path): identity changed during delete")
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .identityChanged))
        }

        // A late filesystem change must be visible to the rule's final validator.
        await beforeMove?(path)
        guard !Task.isCancelled else {
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .cancelled))
        }
        let contract = ruleContract?(path)
        if enforceCleanupSafety {
            guard additionalValidation != nil else {
                return DeleteReport.Outcome(path: path, result: .skipped(reason: .safetyCheck("Cleanup rule evidence is missing; rescan before removal.")))
            }
            guard let measuredBytes = cleanupSize(path: path, whitelist: whitelist, contract: contract) else {
                return DeleteReport.Outcome(path: path, result: .skipped(reason: .safetyCheck("Protected content or incomplete evidence; item kept.")))
            }
            bytes = measuredBytes
            let probeTimeout = contract?.budget.activityProbeTimeout ?? MoleScanBudget.standard.activityProbeTimeout
            if let reason = await CleanupActivityGuard.reason(for: path, timeout: probeTimeout) {
                return DeleteReport.Outcome(path: path, result: .skipped(reason: .safetyCheck(reason)))
            }
        }
        if let reason = await additionalValidation?(path) {
            await OperationLog.shared.record("Skipped \(path): \(reason)")
            // A deliberate Mole refusal is a kept item, not an unexpected Trash error.
            let result: DeleteReport.Outcome.Result = requirePreviewIdentity
                ? .skipped(reason: .safetyCheck(reason)) : .failed(message: reason)
            return DeleteReport.Outcome(path: path, result: result)
        }

        // Cancellation can arrive during measurement or an awaited guard, not just between rows.
        guard !Task.isCancelled else {
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .cancelled))
        }

        if let protections {
            let current = WhitelistStore.snapshot(from: protectionURL)
            guard current.error == nil, current.entries == protections.entries else {
                return DeleteReport.Outcome(path: path, result: .skipped(reason: .safetyCheck(current.error ?? "Protection settings changed; rescan before removal.")))
            }
        }
        if let reason = PathValidator.validate(path: path, whitelist: whitelist) {
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .invalidPath(reason)))
        }

        // Awaited probes allow nested changes that do not change the parent's binding.
        if enforceCleanupSafety {
            guard let measuredBytes = cleanupSize(path: path, whitelist: whitelist, contract: contract) else {
                return DeleteReport.Outcome(path: path, result: .skipped(reason: .safetyCheck("Protected content or incomplete evidence; item kept.")))
            }
            bytes = measuredBytes
        }
        guard !Task.isCancelled else {
            return DeleteReport.Outcome(path: path, result: .skipped(reason: .cancelled))
        }

        // Final bindings follow every awaited guard. The Trash API cannot make these
        // pathname checks atomic with its move, so a residual race remains.
        guard PathBinding.read(path: path) == binding else {
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

    private func cleanupSize(path: String, whitelist: Set<String>, contract: MoleRuleContract?) -> Int64? {
        let budget = contract?.budget ?? .standard
        let measured = FileTreeMeasurement.read(URL(fileURLWithPath: path),
            entryLimit: budget.entryLimit, timeout: budget.measurementTimeout,
            stopAtSafetyEvidence: true, whitelist: whitelist,
            policy: contract?.evidencePolicy ?? .strict, containmentRoot: contract?.containmentRoot)
        // Mirror removalProtectionReason's full evidence set so the sink stays
        // self-sufficient even if the mandatory-validator contract ever relaxes.
        guard measured.status == .complete, measured.protectedPath == nil,
              !measured.containsRepository, !measured.containsCredentials,
              !measured.containsSymbolicLinks, !measured.containsCloudPlaceholders else { return nil }
        return measured.bytes
    }
}
