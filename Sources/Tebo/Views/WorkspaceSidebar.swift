import SwiftUI

struct WorkspaceSidebar: View {
    @Binding var workspace: CleanupWorkspace
    @Binding var page: WorkspacePage
    let activity: WorkspaceActivity
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowDragArea().frame(height: 73)
            HStack(spacing: 12) {
                TeboLogo(size: 37)
                Text("Tebo").font(.system(size: 20, weight: .semibold)).tracking(-0.6)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
            workspaceSwitcher.padding(.horizontal, 18).padding(.bottom, 17)
            ScrollView {
                VStack(spacing: 6) {
                    navigationRow(.overview)
                    ForEach(workspace.pages) { navigationRow($0) }
                    Rectangle().fill(TeboPalette.line).frame(height: 1)
                        .padding(.horizontal, 6).padding(.top, 17).padding(.bottom, 12)
                    navigationRow(.autoClean, chevron: true)
                    SettingsLink {
                        HStack(spacing: 16) {
                            Image(systemName: "gearshape").font(.system(size: 19)).frame(width: 24)
                            Text("Settings").font(.system(size: 14))
                            Spacer()
                        }
                        .padding(.horizontal, 12).frame(height: 44).contentShape(Rectangle())
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
            .padding(.horizontal, 24).padding(.bottom, 22)
        }
        .background(TeboPalette.sidebar)
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
                                RoundedRectangle(cornerRadius: 7).fill(TeboPalette.card)
                                    .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(workspace == candidate ? .isSelected : [])
            }
        }
        .padding(3)
        .background(TeboPalette.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain).accessibilityLabel("Cleanup workspace")
    }

    private func navigationRow(_ destination: WorkspacePage, chevron: Bool = false) -> some View {
        Button { page = destination } label: {
            HStack(spacing: 16) {
                SidebarSymbol(page: destination).frame(width: 24, height: 20)
                Text(destination.title).font(.system(size: 14))
                Spacer(minLength: 2)
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .light))
                } else if let key = destination.tabID, appState.resultsByTab[key] != nil {
                    Text(TeboBytes.text(appState.results(for: key).reduce(0) { $0 + $1.sizeBytes }))
                        .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(TeboPalette.secondary)
                }
            }
            .padding(.horizontal, 12).frame(height: 44)
            .background(page == destination ? TeboPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(page == destination ? .isSelected : [])
    }
}
