import SwiftUI

// MARK: - Shared UI components
// The pieces every tab uses. The visual language itself lives in TeboTheme.swift.

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
