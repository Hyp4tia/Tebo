import SwiftUI

// MARK: - PermissionsBanner
// Shown until Full Disk Access is granted. Without it the app silently cannot see other apps'
// caches, which looks exactly like "the scan found nothing" — so we say it out loud at the top.

struct PermissionsBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Full Disk Access is off")
                    .font(.callout).bold()
                Text("Tebo can still clean its own data, but other apps' caches and containers stay invisible. Grant access in System Settings, then re-check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Open System Settings") { PermissionProbe.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Re-check") { Task { await appState.refreshTooling() } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
