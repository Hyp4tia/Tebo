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
            HStack {
                StatCard(
                    title: "Free",
                    value: status?.disk.displayAvailable ?? "unavailable",
                    systemImage: "internaldrive"
                )
                StatCard(
                    title: "Volume",
                    value: status?.disk.displayTotal ?? "unavailable",
                    systemImage: "externaldrive"
                )
                StatCard(
                    title: "Snapshots",
                    value: snapshotText,
                    systemImage: "clock.arrow.circlepath"
                )
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
                            Label(detail, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

    private func runScan(engine: EngineStatus) async -> [ScanResult] {
        guard case .ready(let engineURL, _, _) = engine else {
            appState.setScanNote("Engine not available — largest files cannot be listed.", for: "disk")
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
