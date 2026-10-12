import AppKit
import SwiftUI

struct UninstallView: View {
    @Environment(AppState.self) private var appState
    @Environment(WorkspaceActivity.self) private var activity
    @Environment(\.workspaceSearch) private var search
    @State private var apps: [InstalledApplication] = []
    @State private var plan: UninstallPlan?
    @State private var selectedPaths: Set<String> = []
    @State private var loading = false
    @State private var removing = false
    @State private var showConfirmation = false
    @State private var note: String?
    @State private var planTask: Task<Void, Never>?
    private let uninstaller = ApplicationUninstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                MolePageHeading(title: "Uninstall", detail: "Review an app and the files that belong to it", symbol: "app.badge")
                Spacer()
                if plan != nil {
                    Button("All apps") { plan = nil; note = nil }
                } else {
                    Button("Refresh") { loadApps() }.disabled(loading)
                }
            }
            if loading {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading installed apps…").font(.callout) }
            }
            if let plan { planContent(plan) }
            else { inventory }
        }
        .padding(24)
        .task { if apps.isEmpty { loadApps() } }
        .onDisappear { planTask?.cancel() }
        .confirmationDialog("Move the selected app and related files to the Trash?", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { performUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedPaths.count) reviewed items. You can recover them from the Trash.")
        }
    }

    private var inventory: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(apps.count) applications found").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }) { app in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable().frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).font(.callout.weight(.medium))
                                Text(app.version.map { "Version \($0)" } ?? app.bundleID)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let reason = app.protectedReason {
                                Image(systemName: "lock").foregroundStyle(.secondary).help(reason)
                            }
                            Button("Review") { prepare(app) }.disabled(app.protectedReason != nil || loading)
                        }.teboCard(padding: 12)
                    }
                    if apps.isEmpty && !loading {
                        TeboEmptyState(systemImage: "app", title: "No applications found", message: "Refresh to check Applications and your personal Applications folder.")
                    }
                }
            }
        }
    }

    private func planContent(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app.path)).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(plan.app.name).font(.title3.weight(.semibold))
                    TeboPath(path: plan.app.path)
                }
                Spacer()
                Text(plan.rows.isEmpty ? "Kept" : (plan.rows.contains { !$0.isSizeComplete } ? "≥ " : "") + TeboBytes.text(plan.rows.reduce(0) { $0 + $1.sizeBytes }))
                    .font(.title3).monospacedDigit()
            }.teboCard()
            HStack(spacing: 12) {
                Button("Select all") { selectedPaths = Set(plan.rows.map(\.path)) }
                Button("Clear") { selectedPaths.removeAll() }
                Spacer()
                Toggle("Preview", isOn: Binding(get: { appState.dryRunEnabled }, set: { appState.dryRunEnabled = $0 }))
                    .toggleStyle(.switch).controlSize(.small)
            }.disabled(removing || plan.rows.isEmpty)
            if plan.rows.isEmpty {
                Text(plan.kept.first?.detail ?? "No removable items were found.")
                    .font(.callout).foregroundStyle(TeboPalette.secondary)
            }
            ReviewPanel(note: note, advisories: plan.kept)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.rows.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }) { row in
                        HStack(spacing: 10) {
                            Toggle("Select \(row.displayName)", isOn: Binding(get: { selectedPaths.contains(row.path) }, set: { selected in
                                if selected { selectedPaths.insert(row.path) } else { selectedPaths.remove(row.path) }
                            })).toggleStyle(.checkbox).labelsHidden()
                            Image(systemName: row.category == "Application" ? "app" : "doc")
                                .foregroundStyle(TeboPalette.violet)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.category).font(.callout.weight(.medium))
                                TeboPath(path: row.path)
                            }
                            Spacer()
                            TeboNumber(text: row.displaySize)
                        }.teboCard(padding: 12).disabled(removing)
                    }
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Text("\(selectedPaths.count) items selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if appState.dryRunEnabled {
                        note = "Preview only: nothing moved. Turn Preview off when you are ready."
                        Task { await OperationLog.shared.record("Uninstall \(plan.app.name): previewed \(selectedPaths.count) selected items") }
                    } else { showConfirmation = true }
                } label: {
                    Label(appState.dryRunEnabled ? "Preview uninstall" : "Move to Trash", systemImage: appState.dryRunEnabled ? "eye" : "trash")
                }
                .buttonStyle(TeboPrimaryButtonStyle()).disabled(selectedPaths.isEmpty || removing)
            }
        }
    }

    private func loadApps() {
        loading = true
        Task {
            apps = await Task.detached(priority: .utility) { uninstaller.inventory() }.value
            loading = false
        }
    }
    private func runningIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    private func prepare(_ app: InstalledApplication) {
        loading = true; note = nil
        let running = runningIDs(), whitelist = appState.whitelist
        let started = Date.now
        planTask?.cancel()
        planTask = Task {
            let found = await uninstaller.plan(for: app, whitelist: whitelist, runningBundleIDs: running)
            guard !Task.isCancelled else { return }
            plan = found; selectedPaths = Set(found.rows.filter { $0.path == app.path }.map(\.path))
            if found.rows.isEmpty { appState.resultsByTab.removeValue(forKey: "uninstall") }
            else { appState.resultsByTab["uninstall"] = found.rows }
            activity.recordScan(started: started)
            await OperationLog.shared.record("Uninstall \(app.name): reviewed \(found.rows.count) items")
            loading = false
        }
    }
    private func performUninstall() {
        guard let plan, !appState.dryRunEnabled else { return }
        removing = true
        let paths = selectedPaths, running = runningIDs(), whitelist = appState.whitelist
        Task {
            let report = await uninstaller.execute(plan, selectedPaths: paths, whitelist: whitelist, runningBundleIDs: running)
            activity.recordRemoval(report); note = report.summary
            let moved = Set(report.outcomes.compactMap { result -> String? in
                if case .trashed = result.result { return result.path }; return nil
            })
            let remaining = plan.rows.filter { !moved.contains($0.path) }
            self.plan = UninstallPlan(app: plan.app, rows: remaining, identities: plan.identities, kept: plan.kept)
            appState.resultsByTab["uninstall"] = remaining
            selectedPaths.subtract(moved); removing = false
            if moved.contains(plan.app.path) { apps.removeAll { $0.path == plan.app.path } }
        }
    }
}
