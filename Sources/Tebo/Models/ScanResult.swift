import Foundation

// MARK: - ScanResult
// One file/folder the engine thinks we can clean.
// Kept tiny on purpose: UI only needs path + size + reason.

/// A single cleanable item found by a scan.
/// `Sendable` so it can safely cross Task / actor boundaries.
public struct ScanResult: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let path: String
    public let sizeBytes: Int64
    public let category: String   // e.g. "User app cache", "Duplicates"
    public let reason: String     // Why it is safe, shown in UI
    /// True when the scanner that produced this row also knows a rule that makes it a safe
    /// default choice (Mole's "safe" risk tier, a duplicate copy beyond the first per group, the
    /// largest files, a stale installer). "Select recommended" ticks exactly these rows and
    /// nothing else; no rule is invented at display time.
    public let recommendedForSelection: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        sizeBytes: Int64,
        category: String,
        reason: String,
        recommendedForSelection: Bool = false
    ) {
        self.id = id
        self.path = path
        self.sizeBytes = sizeBytes
        self.category = category
        self.reason = reason
        self.recommendedForSelection = recommendedForSelection
    }

    /// Human-readable size, e.g. "1.2 GB". Cached formatter = fast.
    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// Last path component for loud row titles ("Chrome" not the full path).
    public var displayName: String {
        (path as NSString).lastPathComponent
    }
}

// MARK: - Scan Summary
// Lightweight totals shown at the top of each tab.

/// Totals for one completed scan pass.
public struct ScanSummary: Sendable, Equatable {
    public var itemCount: Int = 0
    public var totalBytes: Int64 = 0

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}
