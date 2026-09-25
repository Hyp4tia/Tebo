import Foundation

// MARK: - SelectionPlan
// The maths behind the selection buttons, kept pure so the rules are testable without a window.
// Every rule here is also stated in the UI next to the button it drives.

enum SelectionPlan {

    /// Rows to keep when a grouped tool offers "one copy per group": the largest file of each
    /// group. Size is the only honest tiebreak the engine's output carries (no timestamps), and
    /// for images the largest file is the highest-resolution copy in practice.
    static func keepersByGroup(rows: [ScanResult], groups: [UUID: String]) -> Set<UUID> {
        var best: [String: ScanResult] = [:]
        for row in rows {
            guard let group = groups[row.id] else { continue }
            if let current = best[group], current.sizeBytes >= row.sizeBytes { continue }
            best[group] = row
        }
        return Set(best.values.map(\.id))
    }

    /// The N largest rows, biggest first.
    static func biggest(_ limit: Int, in rows: [ScanResult]) -> [UUID] {
        guard limit > 0 else { return [] }
        return rows
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(limit)
            .map(\.id)
    }
}
