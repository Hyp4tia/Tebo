import Foundation

/// One cleanup result per path, regardless of how many read-only scanners found it.
enum CleanResultCombiner {
    static func merge(tableRows: [ScanResult], orphans: [OrphanRow], installers: [InstallerFile], now: Date = .now) -> [ScanResult] {
        var seen: Set<String> = []
        var result = tableRows.filter { seen.insert($0.path).inserted }
        for orphan in orphans where seen.insert(orphan.path).inserted {
            result.append(ScanResult(id: orphan.id, path: orphan.path, sizeBytes: orphan.sizeBytes,
                category: "Orphaned app data", reason: orphan.reason, isSizeComplete: orphan.isSizeComplete))
        }
        for installer in installers where seen.insert(installer.path).inserted {
            // A cache-folder result can already include an installer inside it.
            // Offer that content once so totals and Trash previews do not overlap.
            guard !result.contains(where: { installer.path.hasPrefix($0.path + "/") }) else { continue }
            result.append(ScanResult(id: installer.id, path: installer.path, sizeBytes: installer.sizeBytes,
                category: "Downloaded Installers", reason: "\(installer.kind.rawValue.uppercased()) installer in \(installer.source)",
                recommendedForSelection: installer.lastModified.map { $0 < now.addingTimeInterval(-30 * 86_400) } ?? false))
        }
        return result
    }
}
