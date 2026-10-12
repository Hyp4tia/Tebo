import Foundation

struct ProjectArtifactReport: Sendable {
    let rows: [ScanResult]
    let kept: [AdvisoryRow]
    let partial: Bool
}

struct ProjectArtifactScanner: Sendable {
    let roots: [String]
    let maxDepth: Int
    init(roots: [String] = MolePaths.projectSearchRoots, maxDepth: Int = 6) {
        self.roots = roots; self.maxDepth = maxDepth
    }

    func scan(whitelist: Set<String>, timeout: TimeInterval = 60) async -> ProjectArtifactReport {
        let worker = Task.detached(priority: .utility) { await scanOffMain(whitelist: whitelist, timeout: timeout) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private func scanOffMain(whitelist: Set<String>, timeout: TimeInterval) async -> ProjectArtifactReport {
        let deadline = Date.now.addingTimeInterval(timeout)
        var pending = roots.map { (URL(fileURLWithPath: $0).resolvingSymlinksInPath(), 0) }
        var rows: [ScanResult] = [], kept: [AdvisoryRow] = []
        var visited: Set<String> = []
        var partial = false
        var walked = 0
        while let (directory, depth) = pending.popLast() {
            if Task.isCancelled || Date.now >= deadline || walked > 20_000 || rows.count >= 500 { partial = true; break }
            guard visited.insert(directory.path).inserted else { continue }
            guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]) else {
                partial = true; continue
            }
            for child in children {
                walked += 1
                if Task.isCancelled || Date.now >= deadline { partial = true; break }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let name = child.lastPathComponent
                if [".git", ".hg", ".svn"].contains(name) { continue }
                if MolePaths.purgeFolderNames.contains(name) {
                    let reason = await protectionReason(for: child, whitelist: whitelist)
                    if let reason {
                        kept.append(.init(id: child.path, title: name, detail: reason, source: child.path)); continue
                    }
                    let measured = FileTreeMeasurement.read(child)
                    let old = measured.newestModification.map { $0 < Date.now.addingTimeInterval(-7 * 86_400) } ?? false
                    rows.append(ScanResult(path: child.path, sizeBytes: measured.bytes,
                        category: directory.lastPathComponent, reason: old ? "Rebuildable \(name), inactive for over 7 days"
                            : "Rebuildable \(name), recent activity: review before removal",
                        recommendedForSelection: old && measured.status == .complete,
                        isSizeComplete: measured.status == .complete))
                } else if depth < maxDepth, !name.hasPrefix(".") || name == ".codex" || name == ".worktrees" {
                    pending.append((child, depth + 1))
                }
            }
        }
        return ProjectArtifactReport(rows: rows.sorted { $0.sizeBytes > $1.sizeBytes }, kept: kept, partial: partial)
    }

    // Reused at discovery and immediately before deletion, as in Mole's purge sink.
    func protectionReason(for url: URL, whitelist: Set<String>) async -> String? {
        if let reason = PathValidator.validate(path: url.path, whitelist: whitelist) { return reason.rawValue }
        guard MolePaths.purgeFolderNames.contains(url.lastPathComponent) else { return "Not a rebuildable artifact folder" }
        let measured = FileTreeMeasurement.read(url, stopAtSafetyEvidence: true)
        if measured.containsRepository { return "Contains a nested repository" }
        if measured.containsCredentials { return "Contains credentials or deployment keys" }
        guard measured.status == .complete else { return "Content scan incomplete; folder kept" }
        // vendor can be authored or intentionally vendored source. Never infer it is disposable.
        if url.lastPathComponent == "vendor" { return "Vendored source is kept" }
        var ancestor = url.deletingLastPathComponent().resolvingSymlinksInPath()
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                let relative = String(url.resolvingSymlinksInPath().path.dropFirst(ancestor.path.count + 1))
                var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                let response = await BoundedProcessRunner.run(executablePath: "/usr/bin/git", arguments: [
                    "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", ancestor.path,
                    "ls-files", "--", ":(top,literal,icase)\(relative)"], timeout: 5, environment: environment)
                guard response.terminationStatus == 0, !response.outputTruncated else { return "Repository contents could not be verified" }
                if !response.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Contains Git-tracked files" }
                break
            }
            ancestor.deleteLastPathComponent()
        }
        return nil
    }
}
