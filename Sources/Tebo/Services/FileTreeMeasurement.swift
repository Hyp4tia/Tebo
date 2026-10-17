import Darwin
import Foundation

enum MeasurementStatus: String, Sendable, Codable { case complete, partial, unavailable }

struct FileTreeMeasurement: Sendable {
    var bytes: Int64 = 0
    var fileCount = 0
    var status: MeasurementStatus = .complete
    var newestModification: Date?
    var containsRepository = false
    var containsCredentials = false
    var protectedPath: String?
    var containsSymbolicLinks = false
    var containsCloudPlaceholders = false

    static func isDataless(flags: UInt32) -> Bool { flags & UInt32(SF_DATALESS) != 0 }

    static func read(_ url: URL, entryLimit: Int = 50_000, timeout: TimeInterval = 4,
                     stopAtSafetyEvidence: Bool = false, whitelist: Set<String> = [],
                     policy: MoleEvidencePolicy = .strict, containmentRoot: String? = nil) -> Self {
        var result = Self()
        let fm = FileManager.default
        var rootInfo = stat()
        guard lstat(url.path, &rootInfo) == 0 else { result.status = .unavailable; return result }
        // Inspect flags before asking providers for descendant metadata, which can hydrate data.
        if isDataless(flags: rootInfo.st_flags) {
            result.containsCloudPlaceholders = true; result.status = .unavailable; return result
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                       .fileSizeKey, .contentModificationDateKey, .volumeIsLocalKey]
        guard let initial = try? url.resourceValues(forKeys: keys), initial.isSymbolicLink != true,
              initial.volumeIsLocal == true else {
            result.status = .unavailable; return result
        }
        result.newestModification = initial.contentModificationDate
        if initial.contentModificationDate == nil { result.status = .partial }
        if !SafetyGate.isAllowed(path: url.path, whitelist: whitelist) {
            result.protectedPath = url.path
            if stopAtSafetyEvidence { result.status = .partial; return result }
        }
        if initial.isDirectory != true {
            guard initial.isRegularFile == true, let size = initial.fileSize else {
                result.status = .unavailable; return result
            }
            result.bytes = Int64(size); result.fileCount = 1
            result.containsCredentials = credentialName(url.lastPathComponent, tolerated: policy.toleratedCredentialNames)
            return result
        }
        let deadline = Date.now.addingTimeInterval(timeout)
        var pending = [url]
        var seen: Set<FileIdentity> = []
        var entries = 0
        while let directory = pending.popLast() {
            guard !Task.isCancelled, Date.now < deadline, entries < entryLimit else {
                result.status = .partial; break
            }
            guard let children = try? fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil) else {
                result.status = directory == url ? .unavailable : .partial
                continue
            }
            for child in children {
                entries += 1
                if entries > entryLimit || Date.now >= deadline || Task.isCancelled {
                    result.status = .partial; return result
                }
                let name = child.lastPathComponent
                // Cache parents must not hide protected data added after the preview.
                if !SafetyGate.isAllowed(path: child.path, whitelist: whitelist) {
                    result.protectedPath = child.path
                    if stopAtSafetyEvidence { result.status = .partial; return result }
                }
                if [".git", ".hg", ".svn"].contains(name),
                   !policy.toleratedRepositoryFragments.contains(where: { child.path.contains($0) }) {
                    result.containsRepository = true
                    if stopAtSafetyEvidence { result.status = .partial; return result }
                }
                result.containsCredentials = result.containsCredentials
                    || credentialName(name, tolerated: policy.toleratedCredentialNames)
                if stopAtSafetyEvidence && result.containsCredentials { result.status = .partial; return result }
                var info = stat()
                guard lstat(child.path, &info) == 0 else { result.status = .partial; continue }
                if isDataless(flags: info.st_flags) {
                    result.containsCloudPlaceholders = true; result.status = .partial; continue
                }
                guard let values = try? child.resourceValues(forKeys: keys) else {
                    result.status = .partial; continue
                }
                if values.isSymbolicLink == true {
                    // A tolerated link must resolve (lexically) inside the rule root;
                    // deleting the item removes the link itself, never its target.
                    if policy.toleratesRootContainedSymlinks, linkIsContained(child, in: containmentRoot) {
                        continue
                    }
                    result.containsSymbolicLinks = true
                    if stopAtSafetyEvidence { result.status = .partial; return result }
                    continue
                }
                guard values.volumeIsLocal == true, info.st_dev == rootInfo.st_dev else {
                    result.status = .partial; continue
                }
                if let modified = values.contentModificationDate {
                    result.newestModification = max(result.newestModification ?? modified, modified)
                } else { result.status = .partial }
                if values.isDirectory == true { pending.append(child) }
                else if values.isRegularFile == true {
                    guard let size = values.fileSize else { result.status = .partial; continue }
                    guard let identity = FileIdentity.read(path: child.path) else { result.status = .partial; continue }
                    if !seen.insert(identity).inserted { continue }
                    result.bytes += Int64(size); result.fileCount += 1
                }
            }
        }
        return result
    }

    /// Lexically resolves a symlink target (readlink only, never follows the link)
    /// and reports whether it stays inside the rule root. Failures fail closed.
    private static func linkIsContained(_ child: URL, in containmentRoot: String?) -> Bool {
        guard let root = containmentRoot, !root.isEmpty else { return false }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: child.path),
              !destination.isEmpty else { return false }
        let resolved = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination).standardizedFileURL.path
            : child.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL.path
        let normalizedRoot = SafetyGate.normalized(root)
        let normalizedLink = SafetyGate.normalized(resolved)
        return normalizedLink == normalizedRoot || normalizedLink.hasPrefix(normalizedRoot + "/")
    }

    private static func credentialName(_ name: String, tolerated: [String] = []) -> Bool {
        let lower = name.lowercased()
        if tolerated.contains(lower) { return false }
        return ["pem", "key", "p12", "pfx", "keystore", "jks", "mobileprovision"].contains((lower as NSString).pathExtension)
            || lower == ".env" || lower.hasPrefix(".env.") || lower == "id_rsa" || lower == "id_ed25519"
            || lower == "keypair.json" || lower.hasSuffix("-keypair.json")
    }
}

struct AnalyzedEntry: Sendable, Identifiable {
    var id: String { path }
    let path: String
    let isDirectory: Bool
    let measurement: FileTreeMeasurement
}

struct FolderAnalysis: Sendable {
    let path: String
    let entries: [AnalyzedEntry]
    let status: MeasurementStatus
    var bytes: Int64 { entries.reduce(0) { $0 + $1.measurement.bytes } }
}

struct NativeDiskAnalyzer: Sendable {
    func analyze(_ path: String, entryLimit: Int = 50_000, timeout: TimeInterval = 30) async -> FolderAnalysis {
        let worker = Task.detached(priority: .utility) {
            let root = URL(fileURLWithPath: path)
            guard let children = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return FolderAnalysis(path: path, entries: [], status: .unavailable)
            }
            let deadline = Date.now.addingTimeInterval(timeout)
            var entries: [AnalyzedEntry] = []
            var status: MeasurementStatus = .complete
            for child in children {
                if Task.isCancelled || Date.now >= deadline { status = .partial; break }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true else { status = .partial; continue }
                let measured = FileTreeMeasurement.read(child, entryLimit: entryLimit,
                    timeout: min(4, max(0.01, deadline.timeIntervalSinceNow)))
                if measured.status != .complete { status = .partial }
                entries.append(AnalyzedEntry(path: child.path, isDirectory: values.isDirectory == true,
                                             measurement: measured))
            }
            return FolderAnalysis(path: path, entries: entries.sorted { $0.measurement.bytes > $1.measurement.bytes }, status: status)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}
