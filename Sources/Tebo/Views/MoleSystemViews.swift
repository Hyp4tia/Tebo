import AppKit
import SwiftUI

struct MoleStatusView: View {
    @State private var snapshot: LiveSystemSnapshot?
    private let service = LiveSystemStatus()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    MolePageHeading(title: "Status", detail: "Live system activity, refreshed every 2 seconds", symbol: "waveform.path.ecg")
                    Spacer()
                    TeboBadge(text: "Read only", systemImage: "eye", tint: TeboPalette.mint)
                }
                HStack(spacing: 12) {
                    StatTile(label: "CPU", value: snapshot?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Sampling…", systemImage: "cpu", tint: TeboPalette.blue)
                    StatTile(label: "Memory", value: snapshot?.system.memory.usedFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "Unavailable", systemImage: "memorychip", tint: TeboPalette.violet)
                }
                if let snapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        TeboSectionHeader(title: "CPU activity", systemImage: "cpu") { Text("\(snapshot.system.activeProcessorCount ?? 0) cores").font(.caption) }
                        if !snapshot.corePercent.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 10) {
                                ForEach(Array(snapshot.corePercent.enumerated()), id: \.offset) { index, percent in
                                    VStack(spacing: 6) {
                                        ProgressView(value: percent, total: 100).tint(TeboPalette.blue)
                                        Text("\(index + 1) · \(Int(percent))%").font(.system(size: 10)).monospacedDigit()
                                    }
                                }
                            }
                        }
                        Text("Load: \(snapshot.load.map { String(format: "%.2f", $0) }.joined(separator: " · "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.teboCard()
                    VStack(spacing: 13) {
                        statusRow("Disk available", symbol: "internaldrive", value: snapshot.system.disk.displayAvailable ?? "Unavailable")
                        statusRow("Disk read", symbol: "arrow.down", value: rate(snapshot.diskReadBytesPerSecond))
                        statusRow("Disk write", symbol: "arrow.up", value: rate(snapshot.diskWriteBytesPerSecond))
                        Divider()
                        statusRow("Network down", symbol: "arrow.down.circle", value: rate(snapshot.downloadBytesPerSecond))
                        statusRow("Network up", symbol: "arrow.up.circle", value: rate(snapshot.uploadBytesPerSecond))
                        if let interface = snapshot.networkInterface { Text("Active interface: \(interface)").font(.caption).foregroundStyle(.secondary) }
                        Divider()
                        statusRow("Battery", symbol: "battery.100percent", value: snapshot.batteryPercent.map { "\($0)%\(snapshot.batteryCharging == true ? " · charging" : "")" } ?? "No battery reported")
                        statusRow("Uptime", symbol: "clock", value: uptime(snapshot.system.uptimeSeconds))
                    }.teboCard()
                    VStack(alignment: .leading, spacing: 12) {
                        TeboSectionHeader(title: "Active processes", systemImage: "list.bullet.rectangle") { EmptyView() }
                        Text("CPU uses one core = 100%. Processes are read-only.").font(.caption).foregroundStyle(.secondary)
                        ForEach(snapshot.processes) { process in
                            HStack {
                                Text(process.name).font(.callout).lineLimit(1)
                                Spacer()
                                Text(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Sampling…")
                                    .frame(width: 72, alignment: .trailing)
                                Text(TeboBytes.text(Int64(clamping: process.memoryBytes)))
                                    .frame(width: 84, alignment: .trailing)
                            }.font(.caption).monospacedDigit()
                        }
                    }.teboCard()
                } else {
                    ProgressView("Reading system status…").frame(maxWidth: .infinity).padding(30)
                }
            }.padding(24)
        }
        .task {
            while !Task.isCancelled {
                snapshot = await service.collect()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
    private func rate(_ value: Double?) -> String {
        value.map { "\(TeboBytes.text(Int64(max(0, $0))))/s" } ?? "Sampling / unavailable"
    }
    private func uptime(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "Unavailable" }
        return "\(Int(seconds) / 86_400)d \(Int(seconds) / 3600 % 24)h"
    }
    private func statusRow(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(TeboPalette.secondary)
            Text(title).font(.callout)
            Spacer()
            Text(value).font(.caption).monospacedDigit()
        }
    }
}

struct MoleOptimizeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.workspaceSearch) private var search
    @State private var results: [String: String] = [:]
    @State private var runningID: String?
    @State private var confirmTask: OptimizeTask?
    @State private var selectedScan: MaintenanceScan?
    @State private var showConfirmation = false
    @State private var showDatabases = false

    var body: some View {
        if showDatabases {
            DatabaseOptimizationView(back: { showDatabases = false })
        } else if let selectedScan {
            MaintenanceReviewView(mode: selectedScan, back: { self.selectedScan = nil })
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MolePageHeading(title: "Optimize", detail: "Maintenance with a clear preview of every action", symbol: "slider.horizontal.3")
                    HStack {
                        Text("Preview protects every maintenance action.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Preview", isOn: Binding(get: { appState.dryRunEnabled }, set: { appState.dryRunEnabled = $0 }))
                            .toggleStyle(.switch).controlSize(.small)
                    }.teboCard()
                    if search.isEmpty || "Database Optimization".localizedCaseInsensitiveContains(search) {
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.badge.checkmark").font(.title3).foregroundStyle(TeboPalette.orange)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Database Optimization").font(.callout.weight(.semibold))
                                Text("Compact closed-app databases, with a backup first").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review") { showDatabases = true }
                        }.teboCard()
                    }
                    ForEach(MaintenanceScan.allCases.filter { search.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(search) }) { mode in
                        HStack(spacing: 12) {
                            Image(systemName: mode.symbol).font(.title3).foregroundStyle(TeboPalette.orange)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(mode.rawValue).font(.callout.weight(.semibold))
                                Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review") { selectedScan = mode }
                        }.teboCard()
                    }
                    ForEach(OptimizeCatalog.groups(), id: \.name) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.name).font(.headline)
                            ForEach(group.items.filter { search.isEmpty || $0.task.title.localizedCaseInsensitiveContains(search) }) { listing in
                                taskCard(listing)
                            }
                        }
                    }
                }.padding(24)
            }
            .confirmationDialog("Run this maintenance action?", isPresented: $showConfirmation, titleVisibility: .visible) {
                Button("Run action") { if let confirmTask { execute(confirmTask) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text(confirmTask?.explanation ?? "") }
        }
    }

    private func taskCard(_ listing: OptimizeTaskListing) -> some View {
        let task = listing.task
        let protected = appState.whitelist.contains { task.id.localizedCaseInsensitiveContains($0) || task.title.localizedCaseInsensitiveContains($0) }
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: task.group == "Finder" ? "folder" : task.group == "Network" ? "network" : task.group == "System" ? "gearshape" : "wrench.and.screwdriver")
                    .foregroundStyle(TeboPalette.orange)
                Text(task.title).font(.callout.weight(.semibold))
                Spacer()
                if !listing.isAvailable { TeboBadge(text: "Unavailable") }
                else if task.needsAdmin { TeboBadge(text: "Admin", systemImage: "lock") }
                else if protected { TeboBadge(text: "Protected", systemImage: "shield") }
                else {
                    Button(runningID == task.id ? "Running…" : appState.dryRunEnabled ? "Preview" : "Run") {
                        if appState.dryRunEnabled {
                            results[task.id] = "Preview only. Nothing changed.\n" + task.commandLines.joined(separator: "\n")
                            Task { await OperationLog.shared.record("Optimize \(task.id): preview only, no changes") }
                        } else { confirmTask = task; showConfirmation = true }
                    }.disabled(runningID != nil)
                }
            }
            Text(task.explanation).font(.caption).foregroundStyle(.secondary)
            if task.needsAdmin && listing.isAvailable {
                Text("Administrator actions stay manual.").font(.caption).foregroundStyle(.secondary)
                Text(task.commandLines.joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
            if let result = results[task.id] { Text(result).font(.caption).textSelection(.enabled) }
        }.teboCard()
    }
    private func execute(_ task: OptimizeTask) {
        guard !appState.dryRunEnabled, !task.needsAdmin else { return }
        runningID = task.id
        Task {
            let result = await OptimizeRunner().run(task, preview: appState.dryRunEnabled, protectedPatterns: appState.whitelist)
            switch result {
            case .preview(let commands): results[task.id] = "Preview only. Nothing changed.\n" + commands.joined(separator: "\n")
            case .skippedProtected: results[task.id] = "Protected. Nothing changed."
            case .succeeded(let output): results[task.id] = output.isEmpty ? "Completed." : output
            case .failed(let code, let error): results[task.id] = "Failed (\(code)): \(error)"
            case .timedOut: results[task.id] = "Timed out and stopped."
            case .skippedNeedsAdmin: results[task.id] = "Administrator action was not run."
            case .skippedUnavailableBinary: results[task.id] = "A required system tool is unavailable."
            }
            runningID = nil
        }
    }
}

private struct DatabaseOptimizationView: View {
    let back: () -> Void
    @Environment(AppState.self) private var appState
    @State private var databases: [MaintenanceDatabase] = []
    @State private var results: [String: String] = [:]
    @State private var running: String?
    @State private var selected: MaintenanceDatabase?
    @State private var confirm = false
    private let service = DatabaseMaintenance()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button("All maintenance", action: back).buttonStyle(.plain).font(.caption)
                MolePageHeading(title: "Database Optimization", detail: "Compact free pages without removing records", symbol: "externaldrive.badge.checkmark")
                Text("Quit the owning app first. Tebo checks integrity and saves a private SQLite backup before optimizing.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Preview only", isOn: Binding(get: { appState.dryRunEnabled }, set: { appState.dryRunEnabled = $0 }))
                    .toggleStyle(.switch)
                if databases.isEmpty {
                    TeboEmptyState(systemImage: "externaldrive", title: "No supported databases found",
                        message: "Readable Mail, Messages and Safari databases appear here. Disk access permissions may limit what is available.")
                }
                ForEach(databases) { database in
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Text(database.name).font(.callout.weight(.semibold))
                            Spacer()
                            Button(running == database.id ? "Working…" : appState.dryRunEnabled ? "Preview" : "Optimize") {
                                if appState.dryRunEnabled { run(database) }
                                else { selected = database; confirm = true }
                            }.disabled(running != nil)
                        }
                        TeboPath(path: database.path)
                        if let result = results[database.id] { Text(result).font(.caption).textSelection(.enabled) }
                    }.teboCard()
                }
            }.padding(24)
        }
        .task { databases = await Task.detached(priority: .utility) { service.candidates() }.value }
        .confirmationDialog("Back up and optimize this database?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Back up and optimize") { if let selected { run(selected) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This compacts unused pages. It does not delete messages, history or mail records.") }
    }
    private func run(_ database: MaintenanceDatabase) {
        running = database.id
        let preview = appState.dryRunEnabled, whitelist = appState.whitelist
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        Task {
            let result = await service.optimize(database, preview: preview, whitelist: whitelist, runningIDs: runningIDs)
            switch result {
            case .preview: results[database.id] = "Preview only. No files or databases changed."
            case .unchanged: results[database.id] = "Already compact. Nothing changed."
            case .optimized(let path): results[database.id] = "Optimized. Backup: \(TeboPath.abbreviate(path))"
            case .skipped(let reason): results[database.id] = "Kept: \(reason)"
            case .failed(let reason): results[database.id] = reason
            }
            running = nil
        }
    }
}

private struct MaintenanceReviewView: View {
    let mode: MaintenanceScan
    let back: () -> Void
    @Environment(AppState.self) private var appState
    @State private var kept: [AdvisoryRow] = []
    var body: some View {
        let whitelist = appState.whitelist
        VStack(alignment: .leading, spacing: 10) {
            Button("All maintenance", action: back).buttonStyle(.plain).font(.caption).padding(.horizontal, 16)
            ScanTab(tabID: "maintenance-\(mode.id)", title: mode.rawValue, subtitle: mode.detail, icon: mode.symbol,
                removalValidator: { path in
                    let running = await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
                    return MaintenanceScanner().removalReason(path: path, mode: mode, whitelist: whitelist, runningIDs: running)
                },
                runScan: {
                    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                    let report = await MaintenanceScanner().scan(mode, whitelist: appState.whitelist, runningIDs: running)
                    kept = report.kept
                    appState.setScanNote("\(report.rows.count) items ready for review. Every removal goes to Trash.", for: "maintenance-\(mode.id)")
                    return report.rows
                }, extraInfo: { ReviewPanel(note: appState.scanNote(for: "maintenance-\(mode.id)"), advisories: kept) })
        }
    }
}
