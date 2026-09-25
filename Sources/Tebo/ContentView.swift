import AppKit
import SwiftUI

// MARK: - ContentView
// Window shell for the six tabs. The chrome is ours (a floating pill bar over a hidden title bar)
// so the whole top edge can carry state: navigation on the left, the one delete-behaviour control
// on the right, and nothing competing for the same pixels.

enum TeboSection: String, CaseIterable, Identifiable {
    case clean, duplicates, apps, disk, health, toolbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: "Clean"
        case .duplicates: "Duplicates"
        case .apps: "Apps"
        case .disk: "Disk"
        case .health: "Health"
        case .toolbox: "Toolbox"
        }
    }

    var symbol: String {
        switch self {
        case .clean: "sparkles"
        case .duplicates: "photo.on.rectangle.angled"
        case .apps: "app.badge"
        case .disk: "internaldrive"
        case .health: "heart.text.square"
        case .toolbox: "wrench.and.screwdriver"
        }
    }

    var help: String {
        switch self {
        case .clean: "Caches, logs and leftovers, biggest first"
        case .duplicates: "Duplicate and similar files, with previews"
        case .apps: "What removed apps left behind"
        case .disk: "What is using the space"
        case .health: "Memory, load and maintenance"
        case .toolbox: "Installers, broken files and the operation log"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState

    @State private var section: TeboSection = .clean
    @State private var hovered: TeboSection?

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider().opacity(0.7)

            if appState.hasFullDiskAccess == false {
                PermissionsBanner()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        // Engine verification and the permission probe each cost a disk read: once per launch.
        .task { await appState.refreshTooling() }
    }

    // MARK: Nav bar

    private var navBar: some View {
        HStack(spacing: 8) {
            // The traffic lights float over this bar; leave the room they need.
            Color.clear.frame(width: 72, height: 1)

            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 20, height: 20)
                Text("Tebo")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.trailing, 10)

            ForEach(TeboSection.allCases) { candidate in
                pill(candidate)
            }

            Spacer(minLength: 12)

            previewControl
            settingsButton
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background { WindowDragArea() }
    }

    private func pill(_ candidate: TeboSection) -> some View {
        let isActive = section == candidate
        return Button {
            section = candidate
        } label: {
            HStack(spacing: 5) {
                Image(systemName: candidate.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(candidate.title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fill(for: candidate, isActive: isActive))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isActive ? 0.12 : 0), lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(candidate.help)
        .onHover { inside in
            if inside { hovered = candidate } else if hovered == candidate { hovered = nil }
        }
    }

    private func fill(for candidate: TeboSection, isActive: Bool) -> Color {
        if isActive { return Color(nsColor: .controlBackgroundColor) }
        return hovered == candidate ? Color.primary.opacity(0.06) : .clear
    }

    /// One control for delete behaviour, labelled so its state is readable at a glance.
    private var previewControl: some View {
        HStack(spacing: 7) {
            Toggle("", isOn: Binding(
                get: { appState.dryRunEnabled },
                set: { appState.dryRunEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()

            Text(appState.dryRunEnabled ? "Preview" : "Deleting")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appState.dryRunEnabled ? Color.secondary : Color.orange)
                .fixedSize()
        }
        .help(appState.dryRunEnabled
              ? "Preview is on: a scan only reports. Nothing is deleted."
              : "Preview is off: ticking rows and confirming moves them to the Trash. Reversible from the Trash.")
    }

    private var settingsButton: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Settings")
    }

    // MARK: Tab content

    @ViewBuilder
    private var content: some View {
        switch section {
        case .clean: CleanView()
        case .duplicates: DuplicatesView()
        case .apps: AppsView()
        case .disk: DiskView()
        case .health: HealthView()
        case .toolbox: ToolboxView()
        }
    }
}

// MARK: - WindowDragArea

/// macOS 14 has no `WindowDragGesture`, so the nav bar drags the window through AppKit:
/// anywhere without a control drags, and double-click zooms, like a title bar should.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.zoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
