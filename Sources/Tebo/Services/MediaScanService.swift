import Foundation

struct MediaScanReport: Sendable {
    var rows: [ScanResult]
    var groups: [UUID: String]
    var details: [UUID: CzkawkaItemDetail]
    var kept: [AdvisoryRow]
    var snapshots: [UUID: MediaFileSnapshot]
    var referenceGuards: [UUID: [String: MediaFileSnapshot]]
}

struct MediaScanService: Sendable {
    let engineURL: URL
    func scan(tool: CzkawkaTool, settings: MediaScanSettings, whitelist: Set<String>) async throws -> MediaScanReport {
        _ = try settings.commonArguments(for: tool)
        let items = try await CzkawkaBridge(engineURL: engineURL).results(tool: tool, in: settings.scanDirectories, settings: settings)
        try Task.checkCancellation()
        var rows: [ScanResult] = [], groups: [UUID: String] = [:], details: [UUID: CzkawkaItemDetail] = [:], kept: [AdvisoryRow] = [], snapshots: [UUID: MediaFileSnapshot] = [:]
        let referenceGroups = Set(items.filter { settings.isReference($0.path) }.compactMap(\.groupID))
        var referenceEvidence: [String: [String: MediaFileSnapshot]] = [:]
        for item in items where settings.isReference(item.path) {
            if let group = item.groupID, let snapshot = MediaFileSnapshot.read(item.path),
               snapshot.size == item.sizeBytes,
               item.modifiedSeconds.map({ $0.rounded(.down) == snapshot.modified.timeIntervalSince1970.rounded(.down) }) ?? true {
                referenceEvidence[group, default: [:]][item.path] = snapshot
            }
        }
        for item in items {
            let reason: String?
            if settings.isReference(item.path) { reason = "Reference folder: always kept" }
            else if tool == .invalidSymlinks { reason = "Invalid link: inspect its destination in Finder; Tebo keeps links read-only" }
            else { reason = SafetyGate.rejectionReason(path: item.path, whitelist: whitelist)?.rawValue }
            if let reason {
                kept.append(.init(id: item.path, title: item.displayName, detail: reason, source: item.path)); continue
            }
            guard let snapshot = MediaFileSnapshot.read(item.path),
                  snapshot.isDirectory || (snapshot.size == item.sizeBytes && item.modifiedSeconds.map { $0.rounded(.down) == snapshot.modified.timeIntervalSince1970.rounded(.down) } ?? true) else {
                kept.append(.init(id: item.path, title: item.displayName, detail: "File changed during scan or could not be checked: kept", source: item.path)); continue
            }
            snapshots[item.id] = snapshot
            if let group = item.groupID { groups[item.id] = group }
            if let detail = item.detail { details[item.id] = detail }
            let description = tool == .bigFiles && settings.smallestFiles ? "Among the smallest non-empty files found"
                : tool == .similarMusic && settings.musicContent ? "Audio fingerprint matches this group"
                : tool == .similarVideos && settings.videoAudio ? "Video audio fingerprint matches this group" : item.reason
            rows.append(ScanResult(id: item.id, path: item.path, sizeBytes: item.sizeBytes, category: tool.displayName, reason: description))
        }
        let keepers = SelectionPlan.keepersByGroup(rows: rows, groups: groups)
        let recommend = tool.isGrouped && (tool != .duplicates || (settings.duplicateMethod == .hash && settings.duplicateHash == "BLAKE3"))
        var referenceGuards: [UUID: [String: MediaFileSnapshot]] = [:]
        rows = rows.map { row in
            let referenceKept = groups[row.id].map { referenceGroups.contains($0) } ?? false
            if referenceKept, let group = groups[row.id] { referenceGuards[row.id] = referenceEvidence[group] ?? [:] }
            let missingReference = referenceKept && referenceGuards[row.id]?.isEmpty == true
            return ScanResult(id: row.id, path: row.path, sizeBytes: row.sizeBytes, category: row.category, reason: row.reason,
                              recommendedForSelection: recommend && !missingReference && groups[row.id] != nil && (referenceKept || !keepers.contains(row.id)))
        }
        return MediaScanReport(rows: rows, groups: groups, details: details, kept: kept, snapshots: snapshots, referenceGuards: referenceGuards)
    }

    static func removalReason(path: String, tool: CzkawkaTool, settings: MediaScanSettings, expected: MediaFileSnapshot?, referenceGuard: [String: MediaFileSnapshot]? = nil) -> String? {
        if settings.isReference(path) { return "Reference folder: kept" }
        guard let expected, MediaFileSnapshot.read(path) == expected else { return "File changed since scan. Scan again before removal." }
        if let referenceGuard, !referenceGuard.contains(where: { MediaFileSnapshot.read($0.key) == $0.value }) {
            return "The matching reference copy changed or is missing. Scan again; working copy kept."
        }
        if tool == .emptyFolders {
            let measured = FileTreeMeasurement.read(URL(fileURLWithPath: path))
            guard measured.status == .complete, measured.fileCount == 0, !measured.containsRepository, !measured.containsCredentials else {
                return "Folder is no longer empty or could not be checked completely: kept"
            }
        }
        return nil
    }
}
