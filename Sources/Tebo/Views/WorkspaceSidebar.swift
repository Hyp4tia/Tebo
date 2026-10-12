import SwiftUI

struct WorkspaceSidebar: View {
    @Binding var workspace: CleanupWorkspace
    @Binding var page: WorkspacePage
    let activity: WorkspaceActivity
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geometry in
            sidebar(compact: geometry.size.height < 710)
        }
        .background(TeboPalette.sidebar.opacity(0.72))
    }

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowDragArea().frame(height: 73)
            HStack(spacing: 12) {
                TeboLogo(size: 37)
                Text("Tebo").font(.system(size: 20, weight: .semibold)).tracking(-0.6)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
            workspaceSwitcher.padding(.horizontal, 18).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: compact ? 4 : 6) {
                    navigationRow(.overview, compact: compact)
                    ForEach(workspace.pages) { navigationRow($0, compact: compact) }
                    Rectangle().fill(TeboPalette.line).frame(height: 1)
                        .padding(.horizontal, 6).padding(.top, compact ? 12 : 17).padding(.bottom, compact ? 6 : 12)
                    navigationRow(.history, chevron: true, compact: compact)
                    SettingsLink {
                        HStack(spacing: 16) {
                            Image(systemName: "gearshape").font(.system(size: 19)).frame(width: 24)
                            Text("Settings").font(.system(size: 14))
                            Spacer()
                        }
                        .padding(.horizontal, 12).frame(height: compact ? 40 : 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
            }
            .scrollIndicators(.hidden)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(TeboPalette.mint).frame(width: 8, height: 8)
                    Text(activity.isScanning ? "Scanning" : "Ready").font(.system(size: 12))
                }
                if let date = activity.lastScan {
                    Text("Last scan: \(date.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Your Mac. A little lighter.")
                }
            }
            .font(.system(size: 11)).foregroundStyle(TeboPalette.muted)
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
    }

    private var workspaceSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(CleanupWorkspace.allCases) { candidate in
                Button { workspace = candidate } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 11.5, weight: workspace == candidate ? .medium : .regular))
                        .frame(maxWidth: .infinity).frame(height: 31)
                        .background {
                            if workspace == candidate {
                                TeboControlSurface(radius: 7)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(workspace == candidate ? .isSelected : [])
            }
        }
        .padding(3)
        .background(TeboInsetSurface(radius: 10))
        .accessibilityElement(children: .contain).accessibilityLabel("Cleanup workspace")
    }

    private func navigationRow(_ destination: WorkspacePage, chevron: Bool = false, compact: Bool) -> some View {
        Button { page = destination } label: {
            HStack(spacing: 16) {
                SidebarSymbol(page: destination).frame(width: 24, height: 20)
                    .symbolVariant(page == destination ? .fill : .none)
                Text(destination.title).font(.system(size: 14))
                    .lineLimit(1).minimumScaleFactor(0.88).layoutPriority(1)
                Spacer(minLength: 2)
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .light))
                } else if destination.resultTabIDs.contains(where: { appState.resultsByTab[$0] != nil }) {
                    let rows = appState.results(forTabs: destination.resultTabIDs)
                    Text((rows.contains { !$0.isSizeComplete } ? "≥ " : "")
                         + TeboBytes.text(rows.reduce(0) { $0 + $1.sizeBytes }))
                        .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(TeboPalette.secondary)
                        .lineLimit(1).minimumScaleFactor(0.82)
                }
            }
            .padding(.horizontal, 12).frame(height: compact ? 40 : 44)
            .background {
                if page == destination { TeboInsetSurface() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(page == destination ? .isSelected : [])
    }
}
