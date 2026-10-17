import SwiftUI

// MARK: - CleanView (Mole `clean`)
// First tab users see. Real sweep of Mole's ported tables: every row is a path that exists on this
// Mac right now, measured on the spot.

struct CleanView: View {
    @Environment(AppState.self) private var appState
    @State private var installerRoots: [String] = []

    var body: some View {
        // Snapshot what the scan needs so the closure captures values, not view state.
        let installerScan = installerConfiguration
        let orphanConfiguration = OrphanScanConfiguration.defaults()
        let cleanupRemovalValidator = CleanupRemovalValidator(
            orphanConfiguration: orphanConfiguration,
            installerConfiguration: installerScan
        )

        ScanTab(
            tabID: "clean",
            title: "Clean",
            subtitle: "Mole cleanup rules, orphan caches and downloaded installers",
            icon: "sparkles",
            scanScope: installerScan.searchRoots,
            recommendedExplanation: "Select recommended chooses supported rebuildable caches only. Other entries need individual review or remain read-only.",
            moleRemovalValidator: { row, currentWhitelist in
                await cleanupRemovalValidator.protectionReason(for: row, whitelist: currentWhitelist)
            },
            runScan: {
                guard appState.refreshProtections() == nil else {
                    appState.setScanNote("Cleanup is blocked until protection settings are reloaded.", for: "clean")
                    return []
                }
                let currentWhitelist = appState.whitelist
                let running = TargetScanner.liveProcessInventory()
                let outcome = await TargetScanner(processInventory: running)
                    .scan(whitelist: currentWhitelist)
                guard !Task.isCancelled else { return [] }
                let orphans = await OrphanScanner(configuration: orphanConfiguration).scan(whitelist: currentWhitelist)
                guard !Task.isCancelled else { return [] }
                let installers = await InstallerFinder(configuration: installerScan).findInstallers()
                guard !Task.isCancelled else { return [] }
                appState.apply(outcome, to: "clean")
                appState.advisoriesByTab["clean", default: []] += orphans.kept.map {
                    AdvisoryRow(id: $0.path, title: $0.name, detail: $0.reason, source: $0.path)
                }
                appState.advisoriesByTab["clean", default: []] += installers.filter {
                    !SafetyGate.isAllowed(path: $0.path, whitelist: currentWhitelist)
                }.map {
                    AdvisoryRow(id: $0.path, title: $0.name, detail: "Protected installer: kept", source: $0.path)
                }
                let merged = CleanResultCombiner.merge(tableRows: outcome.deletable, orphans: orphans.orphans, installers: installers)
                let currentGuard = TargetScanner(processInventory: TargetScanner.liveProcessInventory())
                let runningReasons = currentGuard.runningProtectionReasons(for: merged.map(\.path))
                return merged.filter { row in
                    guard let reason = runningReasons[row.path] else { return true }
                    appState.advisoriesByTab["clean", default: []].append(
                        AdvisoryRow(id: "running-merged:\(row.path)", title: row.displayName,
                                    detail: reason, source: row.path, group: "In use right now"))
                    return false
                }
            },
            extraInfo: {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Installer locations").font(.callout.weight(.medium))
                            Spacer()
                            if !installerRoots.isEmpty {
                                Button("Use defaults") { installerRoots = [] }
                            }
                            Button("Choose folders…") { chooseInstallerRoots() }
                        }
                        Text(installerRoots.isEmpty ? "Standard download locations" : "\(installerRoots.count) selected folders")
                            .font(.caption).foregroundStyle(.secondary)
                    }.teboCard()
                    ReviewPanel(
                        note: appState.scanNote(for: "clean"),
                        advisories: appState.advisories(for: "clean")
                    )
                }
            }
        )
    }

    private var installerConfiguration: InstallerScanConfiguration {
        var configuration = InstallerScanConfiguration.defaults()
        if !installerRoots.isEmpty { configuration.searchRoots = installerRoots }
        return configuration
    }

    private func chooseInstallerRoots() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = true
        picker.prompt = "Use these folders"
        if picker.runModal() == .OK { installerRoots = picker.urls.map(\.path) }
    }
}

// MARK: - Other tabs
// DuplicatesView (czkawka engine) and AppsView/DiskView/HealthView each live in their own file.

