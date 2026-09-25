import SwiftUI

// MARK: - HealthView (system status + Mole's optimize tasks)
// Status cards are read-only. The maintenance list is real work, one task at a time, and says
// plainly when a task needs root: this app never asks for an administrator password.

struct HealthView: View {
    @Environment(AppState.self) private var appState

    @State private var status: SystemStatusReport?
    @State private var groups: [OptimizeTaskGroup] = []
    @State private var results: [String: OptimizeTaskResult] = [:]
    @State private var runningTaskID: String?

    private let runner = OptimizeRunner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Health").font(.largeTitle).bold()
                Text("Live system snapshot, plus maintenance that is safe to run without root")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    StatTile(
                        label: "Memory used",
                        value: memoryValueText,
                        systemImage: "memorychip",
                        detail: memoryDetailText
                    )
                    StatTile(label: "CPU cores", value: "\(status?.activeProcessorCount ?? status?.processorCount ?? 0)", systemImage: "cpu")
                    StatTile(label: "Uptime", value: uptimeText, systemImage: "clock")
                }

                if let fraction = status?.memory.usedFraction {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .controlSize(.small)
                        HStack {
                            Text("\(memoryUsedText) used")
                            Spacer()
                            Text("\(memoryFreeText) free")
                        }
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }

                Text("Maintenance")
                    .font(.title2).bold()
                    .padding(.top, 4)

                if groups.isEmpty {
                    Text("No maintenance tasks are available on this Mac.")
                        .foregroundStyle(.secondary)
                }

                ForEach(groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name).font(.headline)
                        ForEach(group.items) { listing in
                            taskRow(listing)
                            Divider()
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding()
        }
        .task {
            status = StatusReport().collect()
            // isAvailable is probed live: a task whose tool is missing is shown as unavailable
            // rather than attempted and failed.
            groups = OptimizeCatalog.groups()
        }
    }

    // MARK: Row

    @ViewBuilder
    private func taskRow(_ listing: OptimizeTaskListing) -> some View {
        let task = listing.task
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(task.title).font(.callout).bold()
                if task.needsAdmin {
                    Text("needs admin").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if runningTaskID == task.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run") { run(task) }
                        .buttonStyle(.bordered)
                        .disabled(!listing.isAvailable || task.needsAdmin || runningTaskID != nil)
                }
            }
            Text(task.explanation).font(.caption).foregroundStyle(.secondary)
            if !listing.isAvailable && !task.needsAdmin {
                Text("Unavailable: a tool this task needs is not installed.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if task.needsAdmin {
                Text("Run it yourself: \(task.commandLines.joined(separator: " && "))")
                    .font(.caption).monospaced().textSelection(.enabled)
            }
            if let result = results[task.id] {
                Text(describe(result)).font(.caption).foregroundStyle(resultColor(result))
                    .textSelection(.enabled)
            }
            Text(task.citation).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Actions

    private func run(_ task: OptimizeTask) {
        runningTaskID = task.id
        Task {
            let result = await runner.run(task)
            results[task.id] = result
            runningTaskID = nil
        }
    }

    // MARK: Text

    private var memoryValueText: String {
        guard let memory = status?.memory else { return "unavailable" }
        if let fraction = memory.usedFraction {
            return String(format: "%.0f%%", fraction * 100)
        }
        return memory.displayFree.map { "\($0) free" } ?? "unavailable"
    }

    private var memoryDetailText: String? {
        guard let memory = status?.memory, memory.usedFraction != nil else { return nil }
        return memory.displayTotal.map { "of \($0)" }
    }

    private var memoryUsedText: String {
        guard let total = status?.memory.totalBytes, let free = status?.memory.freeBytes else {
            return "unavailable"
        }
        return TeboBytes.text(max(0, total - free))
    }

    private var memoryFreeText: String {
        status?.memory.displayFree ?? "unavailable"
    }

    private var uptimeText: String {
        guard let seconds = status?.uptimeSeconds else { return "unavailable" }
        let hours = Int(seconds) / 3600
        return "\(hours / 24)d \(hours % 24)h"
    }

    private func describe(_ result: OptimizeTaskResult) -> String {
        switch result {
        case .succeeded(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Done." : "Done: \(trimmed.prefix(200))"
        case .failed(let code, let stderr):
            return "Failed (exit \(code)): \(stderr.suffix(200))"
        case .timedOut:
            return "Timed out and was stopped."
        case .skippedNeedsAdmin:
            return "Needs an administrator password, so it was not run."
        case .skippedUnavailableBinary:
            return "A tool this task needs is not installed."
        }
    }

    private func resultColor(_ result: OptimizeTaskResult) -> Color {
        switch result {
        case .succeeded: return .secondary
        case .failed, .timedOut: return .orange
        case .skippedNeedsAdmin, .skippedUnavailableBinary: return .secondary
        }
    }
}
