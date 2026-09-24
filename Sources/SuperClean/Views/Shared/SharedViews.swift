import SwiftUI

// MARK: - Shared UI components
// Tiny reusable pieces so all 6 tabs look the same.
// Keep here (not in 6 copies) = clean code, easy to change once.

/// Big number card at top of each tab, e.g. "4.5 GB reclaimable".
struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2).bold()
            }
            Spacer()
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One scan-result row with checkbox + path + size + reason.
struct PreviewRow: View {
    let item: ScanResult
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.path).font(.body).lineLimit(1).truncationMode(.middle)
                Text("\(item.category) · \(item.reason)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.displaySize).font(.body).monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

/// Scan button that shows a spinner while running.
/// Efficient: disables itself, prevents double-scans.
struct ScanButton: View {
    let title: String
    let isScanning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isScanning { ProgressView().scaleEffect(0.7) }
            Text(isScanning ? "Scanning…" : title)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isScanning)
    }
}
