import SwiftUI

// MARK: - UnavailableTab
// Honest placeholder for a feature that is not built yet. Deliberately shows nothing rather than
// sample rows: fabricated paths and sizes are indistinguishable from real findings once they are
// on screen, and users act on them.

struct UnavailableTab: View {
    let title: String
    let subtitle: String
    let icon: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.largeTitle).bold()
            Text(subtitle).foregroundStyle(.secondary)
            ContentUnavailableView("Not available yet", systemImage: icon, description: Text(reason))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }
}
