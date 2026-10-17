import Foundation

/// One cleanup result per path, regardless of how many read-only scanners found it.
enum CleanResultCombiner {
    private struct Candidate {
        var row: ScanResult
        let insertionOrder: Int
    }

    static func merge(
        tableRows: [ScanResult],
        orphans: [OrphanRow],
        installers: [InstallerFile],
        now: Date = .now
    ) -> [ScanResult] {
        var candidates: [Candidate] = []
        var indexByPath: [String: Int] = [:]

        func insert(_ candidateRow: ScanResult) {
            let row = normalizedReviewOnly(candidateRow)
            let key = normalizedPath(row.path)
            if let index = indexByPath[key] {
                candidates[index].row = mergeExact(candidates[index].row, row)
            } else {
                indexByPath[key] = candidates.count
                candidates.append(Candidate(row: row, insertionOrder: candidates.count))
            }
        }

        tableRows.forEach(insert)
        for orphan in orphans {
            insert(ScanResult(
                id: orphan.id,
                path: orphan.path,
                sizeBytes: orphan.sizeBytes,
                category: "Orphaned app data",
                reason: orphan.reason,
                recommendedForSelection: false,
                isSizeComplete: orphan.isSizeComplete,
                cleanupSource: .orphanCache(orphan.name)
            ))
        }
        for installer in installers {
            insert(ScanResult(
                id: installer.id,
                path: installer.path,
                sizeBytes: installer.sizeBytes,
                category: "Downloaded Installers",
                reason: "\(installer.kind.rawValue.uppercased()) installer in \(installer.source)",
                recommendedForSelection: false,
                cleanupSource: .installer
            ))
        }

        let sorted = candidates.sorted { lhs, rhs in
            let left = pathComponents(lhs.row.path)
            let right = pathComponents(rhs.row.path)
            if left != right { return left.lexicographicallyPrecedes(right) }
            let leftKey = normalizedPath(lhs.row.path)
            let rightKey = normalizedPath(rhs.row.path)
            if leftKey != rightKey { return leftKey < rightKey }
            return lhs.insertionOrder < rhs.insertionOrder
        }

        // Component-wise ordering groups every subtree contiguously. The
        // frontier therefore only compares the current row with its nearest
        // retained ancestor, keeping this pass O(n log n) including sorting.
        var frontier: [ScanResult] = []
        for candidate in sorted {
            let row = candidate.row
            var suppressed = false
            while let ancestor = frontier.last, isStrictAncestor(ancestor.path, of: row.path) {
                let ancestorRank = reviewRank(ancestor)
                let rowRank = reviewRank(row)
                let replaceAncestor = rowRank > ancestorRank
                    || (rowRank == ancestorRank && isReviewOnly(row) && !isReviewOnly(ancestor))
                    || (rowRank == ancestorRank && isReviewOnly(row) && isReviewOnly(ancestor))
                if replaceAncestor {
                    frontier.removeLast()
                } else {
                    suppressed = true
                    break
                }
            }
            if !suppressed { frontier.append(row) }
        }
        return frontier
    }

    private static func mergeExact(_ lhs: ScanResult, _ rhs: ScanResult) -> ScanResult {
        let leftRank = reviewRank(lhs)
        let rightRank = reviewRank(rhs)
        let winner: ScanResult
        let other: ScanResult
        if rightRank > leftRank || (rightRank == leftRank && isReviewOnly(rhs) && !isReviewOnly(lhs)) {
            winner = rhs
            other = lhs
        } else {
            winner = lhs
            other = rhs
        }
        let reason = winner.reason == other.reason
            ? winner.reason
            : "\(winner.reason); conflicting scan evidence: \(other.reason)"
        return ScanResult(
            id: winner.id,
            path: winner.path,
            sizeBytes: max(lhs.sizeBytes, rhs.sizeBytes),
            category: winner.category,
            reason: reason,
            recommendedForSelection: lhs.recommendedForSelection
                && rhs.recommendedForSelection
                && !isReviewOnly(lhs) && !isReviewOnly(rhs),
            isSizeComplete: lhs.isSizeComplete && rhs.isSizeComplete,
            cleanupSource: winner.cleanupSource
        )
    }

    private static func normalizedReviewOnly(_ row: ScanResult) -> ScanResult {
        guard isReviewOnly(row), row.recommendedForSelection else { return row }
        return ScanResult(
            id: row.id,
            path: row.path,
            sizeBytes: row.sizeBytes,
            category: row.category,
            reason: row.reason,
            recommendedForSelection: false,
            isSizeComplete: row.isSizeComplete,
            cleanupSource: row.cleanupSource
        )
    }

    private static func isReviewOnly(_ row: ScanResult) -> Bool {
        switch row.cleanupSource {
        case .installer?, .orphanCache?: true
        default: false
        }
    }

    /// Only an explicitly recommended Mole rule is treated as proven safe.
    /// Unknown/unscoped and review-only rows have higher precedence.
    private static func reviewRank(_ row: ScanResult) -> Int {
        if case .installer? = row.cleanupSource { return 4 }
        if case .orphanCache? = row.cleanupSource { return 3 }
        if case .moleRule? = row.cleanupSource, row.recommendedForSelection { return 0 }
        return 2
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func pathComponents(_ path: String) -> [String] {
        normalizedPath(path).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func isStrictAncestor(_ ancestor: String, of descendant: String) -> Bool {
        let parentParts = pathComponents(ancestor)
        let childParts = pathComponents(descendant)
        return parentParts.count < childParts.count
            && zip(parentParts, childParts).allSatisfy(==)
    }
}
