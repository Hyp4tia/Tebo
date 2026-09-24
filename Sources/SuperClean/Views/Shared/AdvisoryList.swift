import SwiftUI

// MARK: - AdvisoryList
// Renders the rows a scan found but this app must not delete, plus the note about the last scan.
//
// WHY this exists as its own view: those rows must never look selectable. If they were rendered as
// normal result rows the user could tick them, and the delete bar would offer to trash something
// the app deliberately refuses to touch (root-owned paths, snapshots, Trash itself). Keeping them
// in a separate, collapsed, read-only list makes that impossible.

struct AdvisoryList: View {
    let note: String?
    let advisories: [AdvisoryRow]

    @State private var isExpanded = false

    var body: some View {
        if note != nil || !advisories.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let note {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !advisories.isEmpty {
                    DisclosureGroup(isExpanded: $isExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(advisories) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(.callout).bold()
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                                    Text(row.source)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("\(advisories.count) thing\(advisories.count == 1 ? "" : "s") this app will not touch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
