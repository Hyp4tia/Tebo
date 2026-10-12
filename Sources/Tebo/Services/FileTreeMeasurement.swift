import Foundation

enum MeasurementStatus: String, Sendable, Codable { case complete, partial, unavailable }

struct FileTreeMeasurement: Sendable {
    var bytes: Int64 = 0
    var fileCount = 0
    var status: MeasurementStatus = .complete
    var newestModification: Date?
    var containsRepository = false
    var containsCredentials = false

    static func read(_ url: URL, entryLimit: Int = 50_000, timeout: TimeInterval = 4,
                     stopAtSafetyEvidence: Bool = false) -> Self {
        var result = Self()
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                       .fileSizeKey, .contentModificationDateKey]
        guard let initial = try? url.resourceValues(forKeys: keys), initial.isSymbolicLink != true else {
            result.status = .unavailable; return result
        }
        result.newestModification = initial.contentModificationDate
        if initial.isDirectory != true {
            guard initial.isRegularFile == true, let size = initial.fileSize else {
                result.status = .unavailable; return result
            }
            result.bytes = Int64(size); result.fileCount = 1
            result.containsCredentials = credentialName(url.lastPathComponent)
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
                includingPropertiesForKeys: Array(keys)) else {
                result.status = directory == url ? .unavailable : .partial
                continue
            }
            for child in children {
                entries += 1
                if entries > entryLimit || Date.now >= deadline || Task.isCancelled {
                    result.status = .partial; return result
                }
                let name = child.lastPathComponent
                if [".git", ".hg", ".svn"].contains(name) {
                    result.containsRepository = true
                    if stopAtSafetyEvidence { result.status = .partial; return result }
                }
                result.containsCredentials = result.containsCredentials || credentialName(name)
                if stopAtSafetyEvidence && result.containsCredentials { result.status = .partial; return result }
                guard let values = try? child.resourceValues(forKeys: keys) else {
                    result.status = .partial; continue
                }
                guard values.isSymbolicLink != true else { continue }
                if let modified = values.contentModificationDate {
                    result.newestModification = max(result.newestModification ?? modified, modified)
                }
                if values.isDirectory == true { pending.append(child) }
                else if values.isRegularFile == true {
                    guard let size = values.fileSize else { result.status = .partial; continue }
                    if let identity = FileIdentity.read(path: child.path), !seen.insert(identity).inserted { continue }
                    result.bytes += Int64(size); result.fileCount += 1
                }
            }
        }
        return result
    }

    private static func credentialName(_ name: String) -> Bool {
        let lower = name.lowercased()
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
