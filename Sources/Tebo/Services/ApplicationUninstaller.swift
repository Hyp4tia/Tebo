import Foundation

struct InstalledApplication: Sendable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String
    let version: String?
    let protectedReason: String?
}

struct UninstallPlan: Sendable {
    let app: InstalledApplication
    let rows: [ScanResult]
    let identities: [String: FileIdentity]
    let kept: [AdvisoryRow]
}

struct ApplicationUninstaller: Sendable {
    let applicationRoots: [String]
    let home: String

    init(applicationRoots: [String]? = nil, home: String = NSHomeDirectory()) {
        self.home = home
        self.applicationRoots = applicationRoots ?? ["/Applications", "\(home)/Applications"]
    }

    func inventory() -> [InstalledApplication] {
        var applications: [InstalledApplication] = []
        var seen: Set<String> = []
        let deadline = Date.now.addingTimeInterval(10)
        for root in applicationRoots {
            var pending = [(URL(fileURLWithPath: root), 0)]
            while let (directory, depth) = pending.popLast() {
                if Task.isCancelled || applications.count >= 1000 || Date.now >= deadline { break }
                guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
                for child in children {
                    if Task.isCancelled || applications.count >= 1000 || Date.now >= deadline { break }
                    guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                          values.isDirectory == true else { continue }
                    if child.pathExtension.lowercased() == "app" {
                        let resolved = child.resolvingSymlinksInPath()
                        guard seen.insert(resolved.path).inserted,
                              let info = readInfo(resolved), let identifier = info["CFBundleIdentifier"] as? String else { continue }
                        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
                            ?? child.deletingPathExtension().lastPathComponent
                        let reason: String? = identifier.lowercased().hasPrefix("com.apple.") ? "macOS application"
                            : identifier == "com.tebo.app" ? "Tebo is currently in use"
                            : values.isSymbolicLink == true ? "Linked app: remove its link in Finder"
                            : nil
                        applications.append(.init(path: resolved.path, name: name, bundleID: identifier,
                            version: info["CFBundleShortVersionString"] as? String, protectedReason: reason))
                    } else if depth < 2, values.isSymbolicLink != true, !child.lastPathComponent.hasPrefix(".") {
                        pending.append((child, depth + 1))
                    }
                }
            }
        }
        return applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func plan(for app: InstalledApplication, whitelist: Set<String>, runningBundleIDs: Set<String>) async -> UninstallPlan {
        let worker = Task.detached(priority: .utility) {
            var rows: [ScanResult] = []
            var identities: [String: FileIdentity] = [:]
            var kept: [AdvisoryRow] = []
            func keep(_ path: String, _ reason: String) {
                kept.append(.init(id: path, title: URL(fileURLWithPath: path).lastPathComponent,
                                  detail: reason, source: path))
            }
            guard app.protectedReason == nil, !Self.isRunning(app.bundleID, in: runningBundleIDs),
                  Self.isValidBundleID(app.bundleID),
                  self.readInfo(URL(fileURLWithPath: app.path))?["CFBundleIdentifier"] as? String == app.bundleID else {
                keep(app.path, app.protectedReason ?? (Self.isRunning(app.bundleID, in: runningBundleIDs)
                    ? "Quit this app before uninstalling" : "App identity could not be verified"))
                return UninstallPlan(app: app, rows: [], identities: [:], kept: kept)
            }
            let copies = self.inventory().filter { $0.bundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame && $0.path != app.path }
            var candidates: [(String, String)] = [(app.path, "Application")]
            let library = "\(self.home)/Library"
            for (directory, suffix) in [("Caches", ""), ("Application Support", ""), ("Preferences", ".plist"),
                ("Saved Application State", ".savedState"), ("WebKit", ""), ("HTTPStorages", ""), ("Containers", "")] {
                let path = "\(library)/\(directory)/\(app.bundleID)\(suffix)"
                guard FileManager.default.fileExists(atPath: path) else { continue }
                if copies.isEmpty { candidates.append((path, directory)) }
                else { keep(path, "Another installed copy uses this app data") }
            }
            let agents = URL(fileURLWithPath: "\(library)/LaunchAgents")
            for agent in ((try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: [.fileSizeKey])) ?? []).prefix(2000) {
                guard !Task.isCancelled, agent.pathExtension == "plist",
                      let size = try? agent.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
                      let data = try? Data(contentsOf: agent),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String else { continue }
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
                let ownsProgram = program.map { $0.hasPrefix(app.path + "/") } ?? false
                if label == app.bundleID || (ownsProgram && label.hasPrefix(app.bundleID + ".")) {
                    if copies.isEmpty { candidates.append((agent.path, "Launch Agents")) }
                    else { keep(agent.path, "Another installed copy uses this agent") }
                }
            }
            for (path, category) in candidates {
                if Task.isCancelled { break }
                let url = URL(fileURLWithPath: path)
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    keep(path, "Symbolic link kept"); continue
                }
                if let reason = PathValidator.validate(path: path, whitelist: whitelist) {
                    keep(path, reason.rawValue); continue
                }
                guard let identity = FileIdentity.read(path: path) else { keep(path, "Unreadable item"); continue }
                let measured = FileTreeMeasurement.read(url)
                guard measured.status != .unavailable,
                      measured.status == .complete || category == "Application" else {
                    keep(path, "Size scan incomplete; review in Finder"); continue
                }
                identities[path] = identity
                rows.append(ScanResult(path: path, sizeBytes: measured.bytes, category: category,
                    reason: category == "Application" ? "\(app.name) \(app.version ?? "")" : "Exact match for \(app.bundleID)",
                    isSizeComplete: measured.status == .complete))
            }
            return UninstallPlan(app: app, rows: rows, identities: identities, kept: kept)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    func execute(_ plan: UninstallPlan, selectedPaths: Set<String>, whitelist: Set<String>,
                 runningBundleIDs: Set<String>) async -> DeleteReport {
        guard plan.app.protectedReason == nil, !Self.isRunning(plan.app.bundleID, in: runningBundleIDs) else {
            return DeleteReport(outcomes: selectedPaths.map { .init(path: $0, result: .failed(message: "Quit the app before uninstalling")) })
        }
        let valid = plan.rows.filter { selectedPaths.contains($0.path) }
        guard valid.count == selectedPaths.count,
              plan.identities[plan.app.path] == FileIdentity.read(path: plan.app.path),
              readInfo(URL(fileURLWithPath: plan.app.path))?["CFBundleIdentifier"] as? String == plan.app.bundleID else {
            return DeleteReport(outcomes: selectedPaths.map { .init(path: $0, result: .skipped(reason: .identityChanged)) })
        }
        let shared = inventory().contains { $0.bundleID.caseInsensitiveCompare(plan.app.bundleID) == .orderedSame && $0.path != plan.app.path }
        var outcomes: [DeleteReport.Outcome] = []
        let appSelected = selectedPaths.contains(plan.app.path)
        if appSelected {
            let report = await DeletePipeline().trash(paths: [plan.app.path], whitelist: whitelist,
                                                      expectedIdentities: plan.identities)
            outcomes += report.outcomes
            guard report.trashedCount == 1 else {
                outcomes += valid.filter { $0.path != plan.app.path }.map {
                    .init(path: $0.path, result: .failed(message: "App could not be moved; related data was kept"))
                }
                return DeleteReport(outcomes: outcomes)
            }
        }
        let related = valid.filter { $0.path != plan.app.path }.map(\.path)
        if shared {
            outcomes += related.map { .init(path: $0, result: .failed(message: "Another installed copy uses this data")) }
        } else {
            outcomes += await DeletePipeline().trash(paths: related, whitelist: whitelist,
                expectedIdentities: plan.identities).outcomes
        }
        return DeleteReport(outcomes: outcomes)
    }

    private func readInfo(_ url: URL) -> [String: Any]? {
        let file = url.appendingPathComponent("Contents/Info.plist")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 2_000_000, let data = try? Data(contentsOf: file) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
    private static func isValidBundleID(_ id: String) -> Bool {
        id.split(separator: ".").count >= 2 && id.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
            && !id.contains("..")
    }
    private static func isRunning(_ id: String, in identifiers: Set<String>) -> Bool {
        identifiers.contains { $0.caseInsensitiveCompare(id) == .orderedSame || $0.lowercased().hasPrefix(id.lowercased() + ".") }
    }
}
