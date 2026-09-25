import AppKit
import SwiftUI

// MARK: - AppIconIndex
// Real icons for leftovers: the app bundle is usually still on disk (in the Trash, or installed
// under a different location), and its Info.plist gives both the icon and the display name.
// Nothing is invented: when no bundle matches, the row says so instead of showing a fake icon.

@MainActor
final class AppIconIndex {
    static let shared = AppIconIndex()

    struct FoundApp {
        let name: String
        let icon: NSImage
    }

    private var apps: [String: FoundApp] = [:]
    private var loaded = false
    private var loading: Task<[String: (name: String, path: String)], Never>?

    /// Scans the places an app bundle can still be found. One pass per launch, off the main actor,
    /// and every card that asks while it runs waits for the same pass instead of racing it.
    func loadIfNeeded() async {
        if let loading {
            apps = await decorated(loading.value)
            return
        }
        guard !loaded else { return }
        loaded = true
        let task = Task.detached(priority: .utility) { Self.scanForApps() }
        loading = task
        apps = await decorated(task.value)
        loading = nil
    }

    /// Icons come from NSWorkspace, which belongs on the main actor; the disk walk does not.
    private func decorated(
        _ found: [String: (name: String, path: String)]
    ) -> [String: FoundApp] {
        found.mapValues { entry in
            FoundApp(name: entry.name, icon: NSWorkspace.shared.icon(forFile: entry.path))
        }
    }

    /// Exact bundle id first, then the vendor's other app (com.adobe.photoshop → any com.adobe.*),
    /// so a leftover still reads as "Adobe" rather than as an anonymous folder.
    func app(forBundleID bundleID: String) -> FoundApp? {
        if let exact = apps[bundleID] { return exact }
        let vendor = bundleID.split(separator: ".").prefix(2).joined(separator: ".")
        guard vendor.split(separator: ".").count >= 2 else { return nil }
        return apps.first { $0.key.hasPrefix(vendor + ".") }?.value
    }

    private nonisolated static func scanForApps() -> [String: (name: String, path: String)] {
        let home = NSHomeDirectory()
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "\(home)/Applications",
            "\(home)/.Trash",
        ]
        var found: [String: (name: String, path: String)] = [:]
        for root in roots {
            let url = URL(fileURLWithPath: root)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }
            for child in children where child.pathExtension == "app" {
                guard let bundle = Bundle(url: child), let bundleID = bundle.bundleIdentifier else { continue }
                let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? child.deletingPathExtension().lastPathComponent
                found[bundleID] = (name: name, path: child.path)
            }
        }
        return found
    }
}

// MARK: - Owner grouping

/// Which app or vendor a leftover belongs to, derived from its path alone.
enum OrphanOwner {
    /// The key a leftover groups under: a bundle id when the path carries one, otherwise the
    /// first folder name the app left behind.
    static func key(forPath path: String) -> String {
        let home = NSHomeDirectory()
        let shortened = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
        let parts = shortened.split(separator: "/").map(String.init)

        // .../Preferences/<id>.plist, .../LaunchAgents/<id>.plist
        if let file = parts.last, file.hasSuffix(".plist") || file.hasSuffix(".savedState") {
            return file.replacingOccurrences(of: ".savedState", with: "")
                .replacingOccurrences(of: ".plist", with: "")
        }
        // Library/<Root>/<Owner>/... — the owner is the first component that is not a known root.
        let roots: Set<String> = [
            "Library", "Application Support", "Caches", "Containers", "Group Containers",
            "Logs", "Preferences", "LaunchAgents", "Saved Application State", "HTTPStorages",
            "WebKit", "Cookies", "Application Scripts", "Daemon Containers", "Users",
        ]
        if let owner = parts.first(where: { !roots.contains($0) }) { return owner }
        return parts.last ?? path
    }

    /// What to show as the card's title: the app's own name when a bundle matches, else the key.
    static func displayName(forKey key: String, matched: AppIconIndex.FoundApp?) -> String {
        matched?.name ?? key
    }
}

// MARK: - AppLeftoverCard

/// One owner's leftovers: icon, totals, and the individual files under it. Collapsed by default
/// because a real Mac has dozens of owners and hundreds of leftovers.
struct AppLeftoverCard: View {
    let ownerKey: String
    let rows: [ScanResult]
    @Binding var isExpanded: Bool

    @Environment(AppState.self) private var appState

    @State private var matched: AppIconIndex.FoundApp?

    private var totalBytes: Int64 { rows.reduce(0) { $0 + $1.sizeBytes } }
    private var categoryCounts: [(category: String, count: Int)] {
        Dictionary(grouping: rows, by: \.category)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(categoryCounts, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.category)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(rows.filter { $0.category == group.category }) { row in
                                ResultRow(
                                    item: row,
                                    isSelected: appState.selectedIDs.contains(row.id),
                                    onToggle: { appState.toggleSelection(row.id) }
                                )
                            }
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .teboCard(padding: 12)
        .task(id: ownerKey) {
            await AppIconIndex.shared.loadIfNeeded()
            matched = AppIconIndex.shared.app(forBundleID: ownerKey)
        }
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(OrphanOwner.displayName(forKey: ownerKey, matched: matched))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if matched == nil {
                            TeboBadge(text: "app gone", systemImage: "questionmark", tint: .secondary)
                        }
                    }
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                TeboNumber(text: TeboBytes.text(totalBytes), emphasis: true)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var icon: some View {
        if let matched {
            Image(nsImage: matched.icon)
                .resizable()
                .frame(width: 34, height: 34)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 34, height: 34)
        }
    }

    private var summary: String {
        let pieces = categoryCounts.map { "\($0.count) \($0.category.lowercased())" }
        return pieces.joined(separator: " · ")
    }
}
