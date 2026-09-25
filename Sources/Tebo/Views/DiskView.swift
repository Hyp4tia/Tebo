import AppKit
import SwiftUI

// MARK: - DiskView (where the space went)
// Space-focused on purpose: volume usage, the largest files the engine can find, and local
// snapshots as an advisory. CPU, memory and uptime live in Health so the two tabs do not show the
// same numbers twice.

struct DiskView: View {
    @Environment(AppState.self) private var appState

    @State private var status: SystemStatusReport?
    @State private var snapshots: LocalSnapshotReport?
    @State private var root: String = NSHomeDirectory()

    var body: some View {
        let engine = appState.engine
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StatTile(
                    label: "Free",
                    value: status?.disk.displayAvailable ?? "unavailable",
                    systemImage: "internaldrive"
                )
                StatTile(
                    label: "Volume",
                    value: status?.disk.displayTotal ?? "unavailable",
                    systemImage: "externaldrive"
                )
                StatTile(
                    label: "Snapshots",
                    value: snapshotText,
                    systemImage: "clock.arrow.circlepath"
                )
            }

            if let fraction = status?.disk.usedFraction {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .controlSize(.small)
                    HStack {
                        Text("\(usedText) used")
                        Spacer()
                        Text("\(freeText) free")
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }

            ScanTab(
                tabID: "disk",
                title: "Largest files",
                subtitle: "Biggest files under the chosen folder, biggest first",
                icon: "arrow.up.arrow.down",
                runScan: { await runScan(engine: engine) },
                extraInfo: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Looking in \(root)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Change…") { chooseRoot() }
                                .font(.caption)
                        }
                        if let detail = snapshots?.detail {
                            HStack(spacing: 6) {
                                TeboBadge(text: "Snapshot probe", systemImage: "info.circle")
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help(detail)
                            }
                        }
                    }
                }
            )
        }
        .padding()
        .task {
            // Both are cheap, read-only probes; run once when the tab appears.
            status = StatusReport().collect()
            snapshots = await TimeMachineSnapshots().list()
        }
    }

    private var snapshotText: String {
        guard let snapshots else { return "checking…" }
        switch snapshots.status {
        case .succeeded: return "\(snapshots.count)"
        case .timedOut: return "timed out"
        case .unavailable: return "unavailable"
        case .failed: return "unreadable"
        }
    }

    private var usedText: String {
        guard let total = status?.disk.totalBytes, let available = status?.disk.availableBytes else {
            return "unavailable"
        }
        return TeboBytes.text(max(0, total - available))
    }

    private var freeText: String {
        status?.disk.displayAvailable ?? "unavailable"
    }

    private func runScan(engine: EngineStatus) async -> [ScanResult] {
        guard case .ready(let engineURL, _, _) = engine else {
            appState.setScanNote("Engine not available: largest files cannot be listed.", for: "disk")
            return []
        }
        var rows: [ScanResult] = []
        var failure: String?
        do {
            for try await item in CzkawkaBridge(engineURL: engineURL)
                .scan(tool: .bigFiles, in: [URL(fileURLWithPath: root)]) {
                rows.append(ScanResult(
                    id: item.id,
                    path: item.path,
                    sizeBytes: item.sizeBytes,
                    category: "Largest files",
                    reason: item.reason
                ))
            }
        } catch {
            failure = "Listing failed: \(error.localizedDescription)"
        }
        appState.setScanNote(failure ?? "\(rows.count) largest files under \(root)", for: "disk")
        return rows
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.prompt = "Look here"
        if panel.runModal() == .OK, let picked = panel.url { root = picked.path }
    }
}
