import Foundation

enum MaintenanceScan: String, Sendable, CaseIterable, Identifiable {
    case savedStates = "App State Cleanup"
    case brokenPreferences = "Broken Config Repair"
    var id: String { rawValue }
    var detail: String {
        self == .savedStates ? "Saved application states older than 30 days" : "Invalid preference files, reset by moving them to Trash"
    }
    var symbol: String { self == .savedStates ? "clock.badge.xmark" : "doc.badge.gearshape" }
}

struct MaintenanceScanReport: Sendable {
    let rows: [ScanResult]
    let kept: [AdvisoryRow]
}

struct MaintenanceScanner: Sendable {
    let home: String
    init(home: String = NSHomeDirectory()) { self.home = home }
    func scan(_ mode: MaintenanceScan, whitelist: Set<String>, runningIDs: Set<String>) async -> MaintenanceScanReport {
        let worker = Task.detached(priority: .utility) {
            let directory = URL(fileURLWithPath: "\(home)/Library/\(mode == .savedStates ? "Saved Application State" : "Preferences")")
            let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
                return MaintenanceScanReport(rows: [], kept: [.init(id: directory.path, title: "Location unavailable",
                    detail: "This folder could not be read", source: directory.path)])
            }
            var rows: [ScanResult] = [], kept: [AdvisoryRow] = []
            for file in files.prefix(2000) {
                if Task.isCancelled { break }
                let bundleID = file.deletingPathExtension().lastPathComponent
                let relevant = mode == .savedStates ? file.pathExtension == "savedState" : file.pathExtension == "plist"
                guard relevant, let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                if runningIDs.contains(bundleID) || !SafetyGate.isAllowed(path: file.path, whitelist: whitelist) {
                    kept.append(.init(id: file.path, title: file.lastPathComponent, detail: "Running app or protected data", source: file.path)); continue
                }
                if mode == .savedStates {
                    guard let modified = values.contentModificationDate, modified < Date.now.addingTimeInterval(-30 * 86_400) else { continue }
                } else {
                    guard let size = values.fileSize, size > 0, size < 5_242_880, let data = try? Data(contentsOf: file) else { continue }
                    let contents = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    guard !(contents is [String: Any]) else { continue }
                }
                let measured = FileTreeMeasurement.read(file)
                guard measured.status == .complete else { continue }
                if mode == .savedStates, let newest = measured.newestModification,
                   newest >= Date.now.addingTimeInterval(-30 * 86_400) { continue }
                rows.append(ScanResult(path: file.path, sizeBytes: measured.bytes, category: mode.rawValue,
                    reason: mode == .savedStates ? "Inactive saved state, over 30 days old" : "Invalid preference dictionary; app can rebuild its preferences",
                    recommendedForSelection: mode == .savedStates))
            }
            return MaintenanceScanReport(rows: rows, kept: kept)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    func removalReason(path: String, mode: MaintenanceScan, whitelist: Set<String>, runningIDs: Set<String>) -> String? {
        let file = URL(fileURLWithPath: path)
        let directory = "\(home)/Library/\(mode == .savedStates ? "Saved Application State" : "Preferences")"
        guard file.deletingLastPathComponent().resolvingSymlinksInPath().path
                == URL(fileURLWithPath: directory).resolvingSymlinksInPath().path else {
            return "Outside the reviewed maintenance location"
        }
        let owner = file.deletingPathExtension().lastPathComponent.lowercased()
        if runningIDs.contains(where: { $0.lowercased() == owner || $0.lowercased().hasPrefix(owner + ".") }) { return "App is running; item kept" }
        if let reason = PathValidator.validate(path: path, whitelist: whitelist) { return reason.rawValue }
        if mode == .savedStates {
            let measured = FileTreeMeasurement.read(file)
            guard measured.status == .complete else { return "Activity could not be verified" }
            let rootDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard let rootDate, rootDate < Date.now.addingTimeInterval(-30 * 86_400),
                  measured.newestModification.map({ $0 < Date.now.addingTimeInterval(-30 * 86_400) }) ?? true else {
                return "Recent app-state activity; item kept"
            }
        } else {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size < 5_242_880, let data = try? Data(contentsOf: file) else { return "Preference file could not be checked" }
            let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
            if parsed is [String: Any] { return "Preferences are now valid; file kept" }
        }
        return nil
    }
}
