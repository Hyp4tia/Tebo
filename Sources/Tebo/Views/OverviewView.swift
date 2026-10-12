import SwiftUI

struct OverviewView: View {
    let workspace: CleanupWorkspace
    let search: String
    let navigate: (WorkspacePage) -> Void
    @Environment(AppState.self) private var appState

    private var pages: [WorkspacePage] {
        workspace.pages.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.detail.localizedCaseInsensitiveContains(search)
        }
    }
    private var scanned: Bool {
        workspace.pages.filter { workspace == .images || $0.isCleanupSource }
            .contains { $0.tabID.map { appState.resultsByTab[$0] != nil } ?? false }
    }
    private var partial: Bool {
        workspace.pages.filter { workspace == .images || $0.isCleanupSource }
            .compactMap(\.tabID).flatMap { appState.results(for: $0) }.contains { !$0.isSizeComplete }
    }
    private var bytes: Int64 {
        var paths: Set<String> = []
        return workspace.pages.filter { workspace == .images || $0.isCleanupSource }
            .compactMap(\.tabID).flatMap { appState.results(for: $0) }
            .reduce(0) { total, row in paths.insert(row.path).inserted ? total + row.sizeBytes : total }
    }

    var body: some View {
        GeometryReader { geometry in
            let topPadding: CGFloat = geometry.size.height < 690 ? 40 : 60
            let rowHeight = max(54, min(75, (geometry.size.height - topPadding - 270
                                            - CGFloat(max(0, workspace.pages.count - 1)))
                                           / CGFloat(max(1, workspace.pages.count))))
            VStack(alignment: .leading, spacing: 0) {
                Text("A CLEANER MAC, A CLEARER MIND")
                    .font(.system(size: 11.5, weight: .medium)).tracking(1.8)
                    .foregroundStyle(TeboPalette.secondary).padding(.bottom, 14)
                Text(workspace == .files ? "Free up space, keep\nyour Mac running smoothly."
                     : "Make room for memories,\nclear away the copies.")
                    .font(.system(size: 30, weight: .semibold)).tracking(-1.1).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 24)
                scanSummary.padding(.bottom, 15)
                VStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, destination in
                        categoryRow(destination, height: rowHeight)
                        if index < pages.count - 1 {
                            Rectangle().fill(TeboPalette.line.opacity(0.75)).frame(height: 1)
                                .padding(.leading, 96).padding(.trailing, 26)
                        }
                    }
                    if pages.isEmpty {
                        TeboEmptyState(systemImage: "magnifyingglass", title: "No matching categories", message: "Try another search.")
                    }
                }
                .background(TeboPalette.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(TeboPalette.line, lineWidth: 1) }
                .shadow(color: TeboPalette.ink.opacity(0.035), radius: 9, y: 3)
            }
            .padding(.horizontal, 38).padding(.top, topPadding).padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var scanSummary: some View {
        HStack(spacing: 24) {
            ScanRing(isComplete: scanned).frame(width: 51, height: 51)
            VStack(alignment: .leading, spacing: 8) {
                Text(scanned ? "Scan results" : "Ready to scan").font(.system(size: 14, weight: .medium))
                Text(scanned ? "Found \(partial ? "≥ " : "")\(TeboBytes.text(bytes)) \(workspace == .files ? "in cleanup scans" : "in scanned categories")" : "Find a little more breathing room.")
                    .font(.system(size: 12)).foregroundStyle(TeboPalette.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button { navigate(workspace == .files ? .systemJunk : .similarImages) } label: {
                HStack(spacing: 11) {
                    Text(scanned ? "Review" : "Scan Mac")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(TeboPrimaryButtonStyle())
            .help("Open the scan screen to review files. Nothing is removed from the overview.")
        }
        .padding(.horizontal, 27).frame(minHeight: 100)
        .background(TeboPalette.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(TeboPalette.line, lineWidth: 1) }
        .shadow(color: TeboPalette.ink.opacity(0.035), radius: 9, y: 3)
    }

    private func categoryRow(_ destination: WorkspacePage, height: CGFloat) -> some View {
        Button { navigate(destination) } label: {
            HStack(spacing: 19) {
                CategorySymbol(page: destination).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(destination.title).font(.system(size: 14, weight: .medium))
                    Text(destination.detail).font(.system(size: 11.5)).foregroundStyle(TeboPalette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let key = destination.tabID, appState.resultsByTab[key] != nil {
                    Text((appState.results(for: key).contains { !$0.isSizeComplete } ? "≥ " : "")
                         + TeboBytes.text(appState.results(for: key).reduce(0) { $0 + $1.sizeBytes }))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(TeboPalette.secondary)
                } else {
                    Text(destination.overviewHint)
                        .font(.system(size: 11)).foregroundStyle(TeboPalette.muted)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .light))
                    .foregroundStyle(TeboPalette.secondary).padding(.leading, 9)
            }
            .padding(.horizontal, 27).frame(height: height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WorkspaceInspector: View {
    @Binding var search: String
    @Binding var page: WorkspacePage
    let activity: WorkspaceActivity
    var compact = false
    var condensed = false
    var workspace: CleanupWorkspace = .files
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14))
                    TextField(page == .overview ? "Search categories..." : "Search files...", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel("Search")
                }
                .foregroundStyle(TeboPalette.secondary).padding(.horizontal, 12).frame(height: 36)
                .background(TeboPalette.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(TeboPalette.line, lineWidth: 1) }
                Menu {
                    Toggle("Preview only", isOn: Binding(get: { appState.dryRunEnabled }, set: { appState.dryRunEnabled = $0 }))
                    Divider()
                    if workspace == .files {
                        Button("System status") { page = .status }
                        Button("Maintenance") { page = .optimize }
                        Button("Operation history") { page = .history }
                    } else {
                        Button("Health & maintenance") { page = .health }
                        Button("More file tools & history") { page = .toolbox }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 14))
                        .frame(width: 35, height: 36)
                        .background(TeboControlSurface(radius: 11))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Preview settings and more tools")
            }
            .padding(.top, 20)
            ZStack {
                Circle().fill(RadialGradient(colors: [.white.opacity(0.90), TeboPalette.halo.opacity(0.55), .clear],
                                            center: .center, startRadius: 50, endRadius: 105))
                    .frame(width: condensed ? 140 : compact ? 170 : 198,
                           height: condensed ? 140 : compact ? 170 : 198)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.95), TeboPalette.halo.opacity(0.35)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: condensed ? 110 : compact ? 129 : 151,
                           height: condensed ? 110 : compact ? 129 : 151)
                    .overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1) }
                    .shadow(color: TeboPalette.blue.opacity(0.06), radius: 12, y: 4)
                TeboLogo(size: 87).shadow(color: .black.opacity(0.16), radius: 10, y: 7)
            }
            .padding(.top, condensed ? 20 : compact ? 28 : 44)
            Text("Tebo").font(.system(size: 28, weight: .semibold)).tracking(-1).padding(.top, 13)
            Text("Clean. Organize. Breathe.").font(.system(size: 14)).foregroundStyle(TeboPalette.secondary).padding(.top, 9)
            Rectangle().fill(TeboPalette.line).frame(height: 1).padding(.top, condensed ? 18 : compact ? 28 : 40)
                .padding(.bottom, condensed ? 14 : 19)
            metric("Space Freed", symbol: "bag", value: activity.trashedBytes == 0 ? "0 MB" : TeboBytes.text(activity.trashedBytes))
                .help("Size moved to the Trash this session. Emptying the Trash is a separate Finder action.")
            metric("Files Removed", symbol: "doc", value: "\(activity.trashedCount)")
            metric("Scan Time", symbol: "clock", value: activity.durationText)
            Spacer(minLength: 8)
            FocusCard().frame(height: condensed ? 104 : compact ? 148 : 177)
                .padding(.bottom, condensed ? 16 : compact ? 24 : 40)
        }
        .padding(.horizontal, 25).background(TeboPalette.inspector.opacity(0.84))
    }

    private func metric(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 22)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12)).monospacedDigit()
        }
        .frame(height: condensed ? 40 : 44)
    }
}
