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
        workspace.pages.contains { $0.tabID.map { appState.resultsByTab[$0] != nil } ?? false }
    }
    private var bytes: Int64 {
        var paths: Set<String> = []
        return workspace.pages.compactMap(\.tabID).flatMap { appState.results(for: $0) }
            .reduce(0) { total, row in paths.insert(row.path).inserted ? total + row.sizeBytes : total }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("A CLEANER MAC, A CLEARER MIND")
                    .font(.system(size: 11.5, weight: .medium)).tracking(1.8)
                    .foregroundStyle(TeboPalette.secondary).padding(.bottom, 17)
                Text(workspace == .files ? "Free up space, keep\nyour Mac running smoothly."
                     : "Make room for memories,\nclear away the copies.")
                    .font(.system(size: 30, weight: .medium)).tracking(-1.1).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 38)
                scanSummary.padding(.bottom, 15)
                VStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, destination in
                        categoryRow(destination)
                        if index < pages.count - 1 {
                            Rectangle().fill(TeboPalette.line.opacity(0.75)).frame(height: 1)
                                .padding(.leading, 96).padding(.trailing, 26)
                        }
                    }
                    if pages.isEmpty {
                        TeboEmptyState(systemImage: "magnifyingglass", title: "No matching categories", message: "Try another search.")
                    }
                }
                .background(TeboPalette.card.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(TeboPalette.line, lineWidth: 1) }
            }
            .padding(.horizontal, 38).padding(.top, 76).padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var scanSummary: some View {
        HStack(spacing: 24) {
            ScanRing(isComplete: scanned).frame(width: 51, height: 51)
            VStack(alignment: .leading, spacing: 8) {
                Text(scanned ? "Scan results" : "Ready to scan").font(.system(size: 14, weight: .medium))
                Text(scanned ? "Found \(TeboBytes.text(bytes)) in scanned categories" : "Find a little more breathing room.")
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
        .padding(.horizontal, 27).frame(minHeight: 104)
        .background(TeboPalette.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(TeboPalette.line, lineWidth: 1) }
    }

    private func categoryRow(_ destination: WorkspacePage) -> some View {
        Button { navigate(destination) } label: {
            HStack(spacing: 19) {
                CategorySymbol(page: destination).frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 6) {
                    Text(destination.title).font(.system(size: 14, weight: .medium))
                    Text(destination.detail).font(.system(size: 11.5)).foregroundStyle(TeboPalette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let key = destination.tabID, appState.resultsByTab[key] != nil {
                    Text(TeboBytes.text(appState.results(for: key).reduce(0) { $0 + $1.sizeBytes }))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(TeboPalette.secondary)
                } else {
                    Text(destination == .downloads ? "Unavailable" : "Not scanned")
                        .font(.system(size: 11)).foregroundStyle(TeboPalette.muted)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .light))
                    .foregroundStyle(TeboPalette.secondary).padding(.leading, 9)
            }
            .padding(.horizontal, 27).frame(height: 75).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WorkspaceInspector: View {
    @Binding var search: String
    @Binding var page: WorkspacePage
    let activity: WorkspaceActivity
    var compact = false
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
                    Button("Health & maintenance") { page = .health }
                    Button("More file tools & history") { page = .toolbox }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 14))
                        .frame(width: 35, height: 36)
                        .background(TeboPalette.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
                        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(TeboPalette.line, lineWidth: 1) }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Preview settings and more tools")
            }
            .padding(.top, 20)
            ZStack {
                Circle().fill(TeboPalette.halo.opacity(0.3)).frame(width: compact ? 170 : 198, height: compact ? 170 : 198)
                Circle().fill(TeboPalette.card.opacity(0.5)).frame(width: compact ? 129 : 151, height: compact ? 129 : 151)
                TeboLogo(size: 87).shadow(color: .black.opacity(0.16), radius: 10, y: 7)
            }
            .padding(.top, compact ? 28 : 44)
            Text("Tebo").font(.system(size: 28, weight: .semibold)).tracking(-1).padding(.top, 13)
            Text("Clean. Organize. Breathe.").font(.system(size: 14)).foregroundStyle(TeboPalette.secondary).padding(.top, 9)
            Rectangle().fill(TeboPalette.line).frame(height: 1).padding(.top, compact ? 28 : 40).padding(.bottom, 19)
            metric("Space Freed", symbol: "bag", value: activity.trashedBytes == 0 ? "0 MB" : TeboBytes.text(activity.trashedBytes))
                .help("Size moved to the Trash this session. Emptying the Trash is a separate Finder action.")
            metric("Files Removed", symbol: "doc", value: "\(activity.trashedCount)")
            metric("Scan Time", symbol: "clock", value: activity.durationText)
            Spacer(minLength: 8)
            FocusCard().frame(height: compact ? 148 : 177).padding(.bottom, compact ? 24 : 40)
        }
        .padding(.horizontal, 25).background(TeboPalette.inspector)
    }

    private func metric(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 22)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12)).monospacedDigit()
        }
        .frame(height: 44)
    }
}
