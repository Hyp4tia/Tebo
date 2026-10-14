import AppKit
import SwiftUI

enum CleanupWorkspace: String, CaseIterable, Identifiable {
    case files = "File cleanup"
    case images = "Media cleanup"
    var id: String { rawValue }
    var pages: [WorkspacePage] {
        self == .files
            ? [.systemJunk, .applications, .optimize, .largeFiles, .status, .purge]
            : [.similarImages, .duplicates, .similarVideos, .similarMusic, .mediaFiles, .mediaTools]
    }
}

enum WorkspacePage: String, Identifiable {
    case overview, systemJunk, largeFiles, duplicates, downloads, applications, archives
    case similarImages, similarVideos, similarMusic, emptyFolders, emptyFiles
    case autoClean, health, toolbox, optimize, status, purge, history
    case mediaFiles, mediaTools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .systemJunk: "Clean"
        case .largeFiles: "Analyze"
        case .duplicates: "Duplicates"
        case .downloads: "Downloads"
        case .applications: "Uninstall"
        case .archives: "Installers"
        case .optimize: "Optimize"
        case .status: "Status"
        case .purge: "Project Cleanup"
        case .history: "History"
        case .similarImages: "Similar Images"
        case .similarVideos: "Similar Videos"
        case .similarMusic: "Similar Music"
        case .emptyFolders: "Empty Folders"
        case .emptyFiles: "Empty Files"
        case .mediaFiles: "File Checks"
        case .mediaTools: "Media Tools"
        case .autoClean: "Auto Clean"
        case .health: "Health"
        case .toolbox: "Toolbox"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "house"
        case .systemJunk: "trash"
        case .largeFiles: "chart.pie"
        case .emptyFolders: "folder"
        case .duplicates: "square.on.square"
        case .downloads: "arrow.down.to.line"
        case .applications: "app.badge"
        case .archives: "archivebox"
        case .similarImages: "photo.on.rectangle"
        case .similarVideos: "film"
        case .similarMusic: "music.note"
        case .emptyFiles: "doc"
        case .mediaFiles: "checkmark.shield"
        case .mediaTools: "wand.and.stars"
        case .autoClean: "clock.arrow.circlepath"
        case .health: "heart"
        case .toolbox: "wrench.and.screwdriver"
        case .optimize: "slider.horizontal.3"
        case .status: "waveform.path.ecg"
        case .purge: "hammer"
        case .history: "clock.arrow.circlepath"
        }
    }
    var detail: String {
        switch self {
        case .systemJunk: "Caches, leftovers and downloaded installers"
        case .largeFiles: "Explore folders and disk usage"
        case .duplicates: "Exact duplicates by file content"
        case .downloads: "Installer downloads"
        case .applications: "Apps and their related files"
        case .archives: "Downloaded installers and installer ZIPs"
        case .optimize: "Refresh caches and maintain your Mac"
        case .status: "Live CPU, memory and system activity"
        case .purge: "Build outputs and downloaded dependencies"
        case .history: "Scans, maintenance and Trash moves"
        case .similarImages: "Find visually similar images"
        case .similarVideos: "Compare similar video files"
        case .similarMusic: "Find matching music files"
        case .emptyFolders: "Folders with nothing inside"
        case .emptyFiles: "Files with no content"
        case .mediaFiles: "Large, empty, temporary and damaged files"
        case .mediaTools: "Clean metadata, crop and transcode copies"
        default: ""
        }
    }
    var tabID: String? {
        switch self {
        case .systemJunk: "clean"
        case .largeFiles: "analyze"
        case .duplicates: "duplicates"
        case .applications: "uninstall"
        case .archives: "installer"
        case .purge: "purge"
        case .similarImages: "media-image"
        case .similarVideos: "media-video"
        case .similarMusic: "media-music"
        case .emptyFolders: "media-empty-folders"
        case .emptyFiles: "media-empty-files"
        default: nil
        }
    }
    var tint: Color {
        switch self {
        case .systemJunk: TeboPalette.mint
        case .largeFiles, .emptyFolders, .mediaFiles: TeboPalette.blue
        case .duplicates, .similarImages: TeboPalette.purple
        case .downloads, .similarVideos, .mediaTools: TeboPalette.orange
        case .applications, .similarMusic: TeboPalette.violet
        case .optimize: TeboPalette.orange
        case .status: TeboPalette.mint
        case .purge: TeboPalette.purple
        default: TeboPalette.ink
        }
    }
    var isCleanupSource: Bool { [.systemJunk, .applications, .archives, .purge].contains(self) }
    var resultTabIDs: [String] {
        switch self {
        case .mediaFiles: CzkawkaTool.fileChecks.map(\.tabID)
        case .mediaTools: [CzkawkaTool.exifMetadata, .videoTranscode, .videoCrop].map(\.tabID)
        default: tabID.map { [$0] } ?? []
        }
    }
    var overviewHint: String {
        switch self {
        case .optimize: "Review tasks"
        case .status: "View status"
        case .applications: "Browse apps"
        case .mediaFiles: "Browse checks"
        case .mediaTools: "Export copies"
        default: "Not scanned"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspace: CleanupWorkspace = .files
    @State private var page: WorkspacePage = .overview
    @State private var search = ""
    @State private var showPermissions = false
    @State private var activity = WorkspaceActivity()

    var body: some View {
        GeometryReader { geometry in
            let scale = min(1, geometry.size.width / TeboPalette.referenceWidth)
            ZStack {
                TeboArtworkBackground()
                HStack(spacing: 0) {
                    WorkspaceSidebar(workspace: $workspace, page: $page, activity: activity)
                        .frame(width: TeboPalette.sidebarWidth * scale)
                    Rectangle().fill(TeboPalette.line).frame(width: 1)
                    center.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(TeboPalette.canvas.opacity(0.80))
                    Rectangle().fill(TeboPalette.line).frame(width: 1)
                    WorkspaceInspector(search: $search, page: $page, activity: activity,
                                       compact: geometry.size.height < 790,
                                       condensed: geometry.size.height < 720, workspace: workspace)
                        .frame(width: TeboPalette.inspectorWidth * scale)
                }
            }
        }
        .frame(minWidth: 1120, minHeight: 740)
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(TeboPalette.ink)
        .tint(TeboPalette.ink)
        .buttonStyle(TeboButtonStyle())
        .preferredColorScheme(.light)
        .environment(activity)
        .environment(\.workspaceSearch, search)
        .onChange(of: workspace) { _, _ in page = .overview; search = "" }
        .onChange(of: page) { _, _ in appState.clearSelection(); search = "" }
        .task { await appState.refreshTooling() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await appState.refreshPermissions() } }
        }
        .sheet(isPresented: $showPermissions) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Disk access").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Done") { showPermissions = false }
                }
                PermissionsBanner()
            }
            .padding(24)
            .frame(width: 620)
        }
    }

    @ViewBuilder private var center: some View {
        VStack(spacing: 0) {
            if page == .overview {
                OverviewView(workspace: workspace, search: search) { page = $0 }
            } else {
                HStack {
                    Button { page = .overview } label: { Label("Overview", systemImage: "arrow.left") }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(TeboPalette.secondary)
                    Spacer()
                    Text(workspace.rawValue).font(.system(size: 11)).foregroundStyle(TeboPalette.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.top, 38)
                .padding(.bottom, 14)
                detail.id(page).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if appState.hasFullDiskAccess == false {
                Button { showPermissions = true } label: { Image(systemName: "lock.shield").font(.system(size: 13)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(TeboPalette.secondary)
                    .padding(16)
                    .help("Protected access could not be confirmed. Click to re-check or open access settings.")
                    .accessibilityLabel("Disk access settings")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .systemJunk: CleanView()
        case .largeFiles: NativeAnalyzeView()
        case .applications: UninstallView()
        case .optimize: MoleOptimizeView()
        case .status: MoleStatusView()
        case .purge: MolePurgeView()
        case .history: OperationHistoryView()
        case .duplicates: DuplicatesView()
        case .similarImages: DuplicatesView(initialTool: .similarImages)
        case .similarVideos: DuplicatesView(initialTool: .similarVideos)
        case .similarMusic: DuplicatesView(initialTool: .similarMusic)
        case .emptyFolders: DuplicatesView(initialTool: .emptyFolders)
        case .emptyFiles: DuplicatesView(initialTool: .emptyFiles)
        case .mediaFiles: DuplicatesView(initialTool: .bigFiles, tools: CzkawkaTool.fileChecks)
        case .mediaTools: MediaToolsView()
        case .archives: MoleInstallerView()
        case .health: HealthView()
        case .toolbox: ToolboxView()
        case .downloads:
            UnavailableTab(title: "Downloads", subtitle: "A little room for a fresh start", icon: "arrow.down.to.line",
                           reason: "General download cleanup is not available yet. Use Archives to review installer downloads.")
        case .autoClean:
            UnavailableTab(title: "Auto Clean", subtitle: "Keep your Mac feeling light", icon: "clock.arrow.circlepath",
                           reason: "Scheduled cleaning is not available yet. Every existing scan is started by you.")
        case .overview: EmptyView()
        }
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) }
            else { window?.performDrag(with: event) }
        }
    }
}
