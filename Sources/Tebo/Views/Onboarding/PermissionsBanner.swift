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
                Text(appState.hasFullDiskAccess == true ? "Protected access confirmed" : "Protected access could not be confirmed")
                    .font(.callout).bold()
                Text(appState.hasFullDiskAccess == true
                     ? "Tebo can read a protected location. Individual files can still have their own access restrictions."
                     : "Some cleanup locations may be unreadable. If Full Disk Access is already enabled, quit and reopen Tebo, then re-check. Replacing an ad-hoc development build can require removing its old entry and adding the signed app again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Open System Settings") { PermissionProbe.openFullDiskAccessSettings() }
                    .buttonStyle(TeboPrimaryButtonStyle())
                Button("Re-check") { Task { await appState.refreshPermissions() } }
                    .buttonStyle(TeboButtonStyle())
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
