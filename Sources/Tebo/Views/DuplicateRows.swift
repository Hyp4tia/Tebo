import SwiftUI

// MARK: - DuplicateLayout
// How a grouped result is shown. "Most similar" exists because the near-identical pairs are the
// ones worth deciding first; the list stays for everything else.

enum DuplicateLayout: String, CaseIterable, Identifiable {
    case list, grid, compare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "List"
        case .grid: "Side by side"
        case .compare: "Most similar"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "rectangle.grid.2x2"
        case .compare: "rectangle.split.2x1"
        }
    }

    var help: String {
        switch self {
        case .list: "One row per file, with its path and size"
        case .grid: "Every group as thumbnails, so lookalikes are obvious"
        case .compare: "The closest pair in each group, largest pair first to decide"
        }
    }
}

// MARK: - Group model

/// One engine group: rows the engine says belong together (same content, or visually similar).
struct DuplicateGroup: Identifiable {
    let id: String
    let rows: [ScanResult]
    /// Smallest difference reported in the group, when the tool measures one.
    let bestDifference: Int?

    var totalBytes: Int64 { rows.reduce(0) { $0 + $1.sizeBytes } }
    var similarityPercent: Int? {
        guard let bestDifference else { return nil }
        return Int((1 - Double(min(max(bestDifference, 0), 40)) / 40) * 100)
    }
    /// The two rows the engine scores as closest to each other, closest first. For groups the
    /// engine does not score (exact duplicates, video), the two largest are the pair to compare.
    var closestPair: [ScanResult] {
        let scored = rows.compactMap { row -> (row: ScanResult, difference: Int)? in
            guard case .similarImage(_, _, let difference)? = details[row.id] else { return nil }
            return (row, difference)
        }
        guard scored.count >= 2 else {
            return Array(rows.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(2))
        }
        return scored.sorted { $0.difference < $1.difference }.prefix(2).map(\.row)
    }
    var remaining: [ScanResult] { rows.filter { row in !closestPair.contains(where: { $0.id == row.id }) } }

    /// Row details, injected so group maths can read dimensions and difference scores.
    var details: [UUID: CzkawkaItemDetail] = [:]
}

// MARK: - DuplicateRowsView

/// Dispatches to the chosen layout. Every layout ticks the same rows, so switching views never
/// changes what is selected.
struct DuplicateRowsView: View {
    let layout: DuplicateLayout
    let tool: CzkawkaTool
    let rows: [ScanResult]

    @Environment(AppState.self) private var appState

    var body: some View {
        let groups = Self.groups(rows: rows, groups: appState.groupByRowID, details: appState.mediaDetailByRowID)
        switch layout {
        case .list:
            ResultSection(
                category: tool.displayName,
                rows: rows.sorted { $0.sizeBytes > $1.sizeBytes },
                isSelected: { appState.selectedIDs.contains($0.id) },
                refreshToken: 0,
                onToggle: { appState.toggleSelection($0.id) },
                onSelectCategory: { all in
                    all
                        ? appState.select(rows.map(\.id))
                        : appState.deselect(rows.map(\.id))
                }
            )
        case .grid:
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    DuplicateGroupCard(
                        index: index + 1,
                        group: group,
                        tool: tool,
                        style: .grid
                    )
                }
            }
        case .compare:
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(compareSorted(groups).enumerated()), id: \.element.id) { index, group in
                    DuplicateGroupCard(
                        index: index + 1,
                        group: group,
                        tool: tool,
                        style: .compare
                    )
                }
            }
        }
    }

    /// Most similar first: difference ascending, then biggest group first.
    private func compareSorted(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.sorted {
            let left = $0.bestDifference ?? Int.max
            let right = $1.bestDifference ?? Int.max
            return left == right ? $0.totalBytes > $1.totalBytes : left < right
        }
    }

    /// Groups in engine order, with per-group details attached.
    static func groups(
        rows: [ScanResult],
        groups: [UUID: String],
        details: [UUID: CzkawkaItemDetail]
    ) -> [DuplicateGroup] {
        let ungrouped = rows.filter { groups[$0.id] == nil }
        var byGroup: [String: [ScanResult]] = [:]
        for row in rows {
            guard let group = groups[row.id] else { continue }
            byGroup[group, default: []].append(row)
        }
        var built = byGroup.map { group, rows -> DuplicateGroup in
            let differences = rows.compactMap { row -> Int? in
                guard case .similarImage(_, _, let difference) = details[row.id] else { return nil }
                return difference
            }
            return DuplicateGroup(
                id: group,
                rows: rows.sorted { $0.sizeBytes > $1.sizeBytes },
                bestDifference: differences.min(),
                details: details
            )
        }
        built.sort { $0.totalBytes > $1.totalBytes }
        // Rows the engine listed without a group still need to be visible and tickable.
        if !ungrouped.isEmpty {
            built.append(DuplicateGroup(
                id: "ungrouped",
                rows: ungrouped.sorted { $0.sizeBytes > $1.sizeBytes },
                bestDifference: nil,
                details: details
            ))
        }
        return built
    }
}

// MARK: - Group card

private struct DuplicateGroupCard: View {
    enum Style { case grid, compare }

    let index: Int
    let group: DuplicateGroup
    let tool: CzkawkaTool
    let style: Style

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch style {
            case .grid: grid
            case .compare: compare
            }
        }
        .teboCard(padding: 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Group \(index)")
                .font(.subheadline.weight(.semibold))
            if let percent = group.similarityPercent {
                TeboBadge(
                    text: "\(percent)% similar",
                    systemImage: "equal.circle",
                    tint: percent >= 95 ? .orange : .secondary
                )
            } else if group.id != "ungrouped" {
                TeboBadge(text: "Identical content", systemImage: "equal.circle", tint: .secondary)
            }
            Text("\(group.rows.count) files · \(TeboBytes.text(group.totalBytes))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Tick the rest") {
                // Keep the largest of the group, tick the others.
                let keep = group.rows.max { $0.sizeBytes < $1.sizeBytes }?.id
                appState.select(group.rows.map(\.id))
                if let keep { appState.deselect([keep]) }
            }
            .buttonStyle(.link)
            .font(.caption)
            .help("Ticks every file in this group except the largest one.")
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 12)], spacing: 12) {
            ForEach(group.rows) { row in
                DuplicateThumbCell(
                    row: row,
                    detail: group.details[row.id],
                    tool: tool,
                    side: 150,
                    isSelected: appState.selectedIDs.contains(row.id)
                ) { appState.toggleSelection(row.id) }
            }
        }
    }

    private var compare: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(group.closestPair) { row in
                    DuplicateThumbCell(
                        row: row,
                        detail: group.details[row.id],
                        tool: tool,
                        side: 240,
                        isSelected: appState.selectedIDs.contains(row.id)
                    ) { appState.toggleSelection(row.id) }
                }
                Spacer(minLength: 0)
            }

            if !group.remaining.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.remaining.count) more in this group")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(group.remaining) { row in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { appState.selectedIDs.contains(row.id) },
                                set: { _ in appState.toggleSelection(row.id) }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            FileThumb(path: row.path, side: 22)
                            Text(row.displayName).font(.caption).lineLimit(1)
                            Spacer()
                            TeboNumber(text: row.displaySize, font: .caption)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Thumbnail cell

/// One image or file in a group: the preview is the point, the tick is on top of it.
private struct DuplicateThumbCell: View {
    let row: ScanResult
    let detail: CzkawkaItemDetail?
    let tool: CzkawkaTool
    let side: CGFloat
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                FileThumb(path: row.path, side: side)
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(6)
            }
            Text(row.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                TeboNumber(text: row.displaySize, font: .caption2)
                if let caption {
                    Text("· \(caption)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .frame(width: side + 16, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.10),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: onToggle)
        .help(row.path)
    }

    /// Dimensions and difference for images, codec/duration for video, tags for music.
    private var caption: String? {
        switch detail {
        case .similarImage(let width, let height, let difference):
            return "\(width)×\(height) · diff \(difference)"
        case .similarVideo(let width, let height, let seconds, let codec):
            return "\(width)×\(height) · \(Int(seconds))s · \(codec)"
        case .similarMusic(let title, let artist, let seconds, _):
            let tag = [title, artist].filter { !$0.isEmpty }.joined(separator: " · ")
            return tag.isEmpty ? "\(seconds)s" : tag
        case .duplicate:
            return nil
        default:
            return nil
        }
    }
}
