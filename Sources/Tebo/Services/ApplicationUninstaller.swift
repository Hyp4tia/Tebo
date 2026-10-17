import Darwin
import Foundation

struct InstalledApplication: Sendable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String
    let version: String?
    let protectedReason: String?
}

enum UninstallProcessEvidence: Sendable, Equatable {
    case running
    case inactive
    case unknown
}

enum UninstallCopyEvidence: Sendable, Equatable {
    case sharedCopy
    case noKnownCopy
    case unknown
}

struct UninstallPlan: Sendable {
    let app: InstalledApplication
    let rows: [ScanResult]
    let identities: [String: FileIdentity]
    let bindings: [String: PathBinding]
    let kept: [AdvisoryRow]
}

struct ApplicationUninstaller: Sendable {
    typealias ProcessProbe = @Sendable (InstalledApplication) -> UninstallProcessEvidence
    typealias CopyProbe = @Sendable (InstalledApplication) -> UninstallCopyEvidence

    let applicationRoots: [String]
    let home: String
    private let processProbe: ProcessProbe
    private let copyProbe: CopyProbe?
    private let protectionURL: URL?

    init(applicationRoots: [String]? = nil, home: String = NSHomeDirectory(),
         processProbe: ProcessProbe? = nil, copyProbe: CopyProbe? = nil, protectionURL: URL? = nil) {
        self.home = home
        self.applicationRoots = applicationRoots ?? ["/Applications", "\(home)/Applications"]
        self.processProbe = processProbe ?? Self.nativeProcessEvidence
        self.copyProbe = copyProbe
        self.protectionURL = protectionURL
    }

    func inventory() -> [InstalledApplication] {
        scanInventory().applications
    }

    func plan(for app: InstalledApplication, whitelist: Set<String>, runningBundleIDs: Set<String>) async -> UninstallPlan {
        let worker = Task.detached(priority: .utility) {
            var rows: [ScanResult] = []
            var identities: [String: FileIdentity] = [:]
            var bindings: [String: PathBinding] = [:]
            var kept: [AdvisoryRow] = []

            func keep(_ path: String, _ reason: String) {
                kept.append(.init(id: path, title: URL(fileURLWithPath: path).lastPathComponent,
                                  detail: reason, source: path))
            }

            guard app.protectedReason == nil,
                  Self.isUninstallableBundleID(app.bundleID),
                  self.isTrustedAppPath(app.path),
                  !Self.isRunning(app.bundleID, in: runningBundleIDs),
                  self.readInfo(URL(fileURLWithPath: app.path))?["CFBundleIdentifier"] as? String == app.bundleID else {
                keep(app.path, app.protectedReason ?? "App identity or installation path could not be verified")
                return UninstallPlan(app: app, rows: [], identities: [:], bindings: [:], kept: kept)
            }

            switch self.processProbe(app) {
            case .running:
                keep(app.path, "An app or bundled helper process is running")
                return UninstallPlan(app: app, rows: [], identities: [:], bindings: [:], kept: kept)
            case .unknown:
                keep(app.path, "Running executable/helper inventory is incomplete; app kept")
                return UninstallPlan(app: app, rows: [], identities: [:], bindings: [:], kept: kept)
            case .inactive:
                break
            }

            let library = "\(self.home)/Library"
            let relatedLocations: [(String, String)] = [
                ("\(library)/Caches/\(app.bundleID)", "Cache data may contain offline or account state; retained read-only"),
                ("\(library)/Application Support/\(app.bundleID)", "Application Support may contain user documents or account state; retained read-only"),
                ("\(library)/Preferences/\(app.bundleID).plist", "Preferences are retained read-only"),
                ("\(library)/Saved Application State/\(app.bundleID).savedState", "Saved user state is retained read-only"),
                ("\(library)/WebKit/\(app.bundleID)", "Website data and authentication state are retained read-only"),
                ("\(library)/HTTPStorages/\(app.bundleID)", "HTTP cookies and session data are retained read-only"),
                ("\(library)/Containers/\(app.bundleID)", "Application container data is retained read-only"),
                ("\(library)/Group Containers", "Shared app-group data is retained read-only"),
                ("\(library)/Keychains", "Security credentials and keychains are retained read-only")
            ]
            for (path, reason) in relatedLocations where FileManager.default.fileExists(atPath: path) {
                keep(path, "\(reason). No exact reviewed app-data removal policy is enabled.")
            }
            self.appendLaunchAgentAdvisories(bundleID: app.bundleID, appPath: app.path, library: library,
                                             kept: &kept)

            let url = URL(fileURLWithPath: app.path)
            if let reason = PathValidator.validate(path: app.path, whitelist: whitelist) {
                keep(app.path, reason.rawValue)
                return UninstallPlan(app: app, rows: [], identities: [:], bindings: [:], kept: kept)
            }
            let measured = FileTreeMeasurement.read(url)
            guard measured.status == .complete,
                  let before = FileIdentity.read(path: app.path),
                  let after = FileIdentity.read(path: app.path), before == after,
                  let binding = PathBinding.read(path: app.path), binding.leaf == after else {
                keep(app.path, "App bundle identity or full content measurement is unavailable; app kept")
                return UninstallPlan(app: app, rows: [], identities: [:], bindings: [:], kept: kept)
            }
            identities[app.path] = after
            bindings[app.path] = binding
            rows.append(ScanResult(path: app.path, sizeBytes: measured.bytes, category: "Application",
                reason: "\(app.name) \(app.version ?? "")", isSizeComplete: true))
            return UninstallPlan(app: app, rows: rows, identities: identities, bindings: bindings, kept: kept)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    func execute(_ plan: UninstallPlan, selectedPaths: Set<String>, whitelist: Set<String>,
                 runningBundleIDs: Set<String>) async -> DeleteReport {
        guard plan.app.protectedReason == nil,
              Self.isUninstallableBundleID(plan.app.bundleID), isTrustedAppPath(plan.app.path),
              !Self.isRunning(plan.app.bundleID, in: runningBundleIDs) else {
            return DeleteReport(outcomes: selectedPaths.map {
                .init(path: $0, result: .skipped(reason: .safetyCheck("Protected identity or active app; item kept.")))
            })
        }
        let valid = plan.rows.filter { selectedPaths.contains($0.path) }
        guard valid.count == selectedPaths.count,
              plan.identities[plan.app.path] == FileIdentity.read(path: plan.app.path),
              plan.bindings[plan.app.path] == PathBinding.read(path: plan.app.path),
              readInfo(URL(fileURLWithPath: plan.app.path))?["CFBundleIdentifier"] as? String == plan.app.bundleID else {
            return DeleteReport(outcomes: selectedPaths.map {
                .init(path: $0, result: .skipped(reason: .identityChanged))
            })
        }

        var outcomes: [DeleteReport.Outcome] = []
        let appSelected = selectedPaths.contains(plan.app.path)
        if appSelected {
            let report = await DeletePipeline().trash(
                paths: [plan.app.path], whitelist: whitelist,
                expectedIdentities: plan.identities, expectedBindings: plan.bindings,
                requirePreviewIdentity: true, enforceCleanupSafety: false, protectionURL: protectionURL,
                additionalValidation: { path in
                    await self.finalRemovalReason(path: path, plan: plan, whitelist: whitelist)
                }
            )
            outcomes += report.outcomes
            guard report.trashedCount == 1 else {
                outcomes += valid.filter { $0.path != plan.app.path }.map {
                    .init(path: $0.path, result: .skipped(reason: .safetyCheck("App could not be moved; related data was kept")))
                }
                return DeleteReport(outcomes: outcomes)
            }
        }

        let related = valid.filter { $0.path != plan.app.path }.map(\.path)
        if !related.isEmpty {
            outcomes += await DeletePipeline().trash(
                paths: related, whitelist: whitelist,
                expectedIdentities: plan.identities, expectedBindings: plan.bindings,
                requirePreviewIdentity: true, enforceCleanupSafety: true, protectionURL: protectionURL,
                additionalValidation: { path in
                    await self.finalRemovalReason(path: path, plan: plan, whitelist: whitelist)
                }
            ).outcomes
        }
        return DeleteReport(outcomes: outcomes)
    }

    private func finalRemovalReason(path: String, plan: UninstallPlan, whitelist: Set<String>) async -> String? {
        let protection = WhitelistStore.snapshot(from: protectionURL)
        if let error = protection.error { return error }
        guard let binding = plan.bindings[path], binding == PathBinding.read(path: path),
              let identity = plan.identities[path], identity == FileIdentity.read(path: path) else {
            return "Item or physical parent changed since uninstall review"
        }
        if let reason = PathValidator.validate(path: path, whitelist: whitelist.union(protection.entries)) {
            return reason.rawValue
        }
        guard isTrustedAppPath(plan.app.path), Self.isUninstallableBundleID(plan.app.bundleID),
              readInfo(URL(fileURLWithPath: plan.app.path))?["CFBundleIdentifier"] as? String == plan.app.bundleID else {
            return "App identity or installation path changed since uninstall review"
        }
        switch processProbe(plan.app) {
        case .running: return "An app or bundled helper process is running"
        case .unknown: return "Running executable/helper inventory is incomplete; item kept"
        case .inactive: break
        }
        guard path == plan.app.path else {
            switch sharedCopyEvidence(for: plan.app) {
            case .sharedCopy:
                return "Another app copy may share this data; data kept"
            case .unknown:
                return "Shared-copy ownership is unknown, including copies outside searched roots; data kept"
            case .noKnownCopy:
                return "No exact reviewed policy authorizes related app-data removal"
            }
        }
        return nil
    }

    private func sharedCopyEvidence(for app: InstalledApplication) -> UninstallCopyEvidence {
        if let copyProbe { return copyProbe(app) }
        let snapshot = scanInventory()
        if snapshot.applications.contains(where: {
            $0.path != app.path && $0.bundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame
        }) { return .sharedCopy }
        guard snapshot.complete else { return .unknown }
        // A complete scan of configured roots still cannot exclude external or unmounted copies.
        return .unknown
    }

    private func appendLaunchAgentAdvisories(bundleID: String, appPath: String, library: String,
                                             kept: inout [AdvisoryRow]) {
        let root = URL(fileURLWithPath: "\(library)/LaunchAgents")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard let agents = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else {
            kept.append(.init(id: root.path, title: root.lastPathComponent,
                detail: "Launch-agent inventory could not be verified; all agents retained", source: root.path))
            return
        }
        guard agents.count <= 2_000 else {
            kept.append(.init(id: root.path, title: root.lastPathComponent,
                detail: "Launch-agent inventory exceeded its safety limit; all agents retained", source: root.path))
            return
        }
        var remainingBytes = 20_000_000
        for agent in agents where agent.pathExtension == "plist" {
            guard let size = try? agent.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                kept.append(.init(id: agent.path, title: agent.lastPathComponent,
                    detail: "Launch-agent ownership could not be verified; retained read-only", source: agent.path))
                continue
            }
            guard size < 2_000_000, size <= remainingBytes else {
                kept.append(.init(id: root.path, title: root.lastPathComponent,
                    detail: "Launch-agent inventory exceeded its safety scan budget; all agents retained", source: root.path))
                return
            }
            remainingBytes -= size
            guard let data = try? Data(contentsOf: agent),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else {
                kept.append(.init(id: agent.path, title: agent.lastPathComponent,
                    detail: "Launch-agent ownership could not be verified; retained read-only", source: agent.path))
                continue
            }
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
            let ownsProgram = program.map { $0.hasPrefix(appPath + "/") } ?? false
            if label == bundleID || (ownsProgram && label.hasPrefix(bundleID + ".")) {
                kept.append(.init(id: agent.path, title: agent.lastPathComponent,
                    detail: "Related launch agent is retained for the app's official uninstall flow", source: agent.path))
            }
        }
    }

    private struct InventorySnapshot: Sendable {
        let applications: [InstalledApplication]
        let complete: Bool
    }

    private func scanInventory() -> InventorySnapshot {
        var applications: [InstalledApplication] = []
        var seen: Set<String> = []
        var complete = true
        let deadline = Date.now.addingTimeInterval(10)
        for rootPath in applicationRoots {
            var pending = [(URL(fileURLWithPath: rootPath), 0)]
            while let (directory, depth) = pending.popLast() {
                if Task.isCancelled || applications.count >= 1_000 || Date.now >= deadline {
                    complete = false
                    break
                }
                guard let directoryValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
                      let children = try? FileManager.default.contentsOfDirectory(at: directory,
                          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                    complete = false
                    continue
                }
                for child in children {
                    if Task.isCancelled || applications.count >= 1_000 || Date.now >= deadline {
                        complete = false
                        break
                    }
                    guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                        complete = false
                        continue
                    }
                    guard values.isDirectory == true else { continue }
                    if child.pathExtension.lowercased() == "app" {
                        let resolved = child.resolvingSymlinksInPath()
                        if self.isCloudPlaceholder(resolved) {
                            guard seen.insert(resolved.path).inserted else { continue }
                            applications.append(.init(path: resolved.path, name: child.deletingPathExtension().lastPathComponent,
                                bundleID: "unknown", version: nil,
                                protectedReason: "Cloud-managed or nonlocal app placeholder; remove only through Finder"))
                            continue
                        }
                        guard let info = readInfo(resolved),
                              let identifier = info["CFBundleIdentifier"] as? String else {
                            complete = false
                            continue
                        }
                        guard seen.insert(resolved.path).inserted else { continue }
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
        return InventorySnapshot(applications: applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }, complete: complete)
    }

    private func readInfo(_ url: URL) -> [String: Any]? {
        let file = url.appendingPathComponent("Contents/Info.plist")
        guard !isCloudPlaceholder(file),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 2_000_000, let data = try? Data(contentsOf: file) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private func isCloudPlaceholder(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, !FileTreeMeasurement.isDataless(flags: info.st_flags),
              let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey]),
              values.volumeIsLocal == true else { return true }
        return values.isUbiquitousItem == true
    }

    private static func nativeProcessEvidence(_ app: InstalledApplication) -> UninstallProcessEvidence {
        let bundlePath = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path
        var pids = [Int32](repeating: 0, count: 65_536)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, Int(bytes) < pids.count * MemoryLayout<Int32>.stride else { return .unknown }
        let count = Int(bytes) / MemoryLayout<Int32>.stride
        var incomplete = false
        for pid in pids.prefix(count) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 1_024)
            let length = buffer.withUnsafeMutableBytes {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            guard length > 0 else {
                if errno != ESRCH { incomplete = true }
                continue
            }
            let executable = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if executable == bundlePath || executable.hasPrefix(bundlePath + "/") { return .running }
        }
        return incomplete ? .unknown : .inactive
    }

    private static func isInSearchRoot(_ path: String, roots: [String]) -> Bool {
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return roots.contains { root in
            let physicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            return candidate.hasPrefix(physicalRoot.hasSuffix("/") ? physicalRoot : physicalRoot + "/")
        }
    }

    private func isTrustedAppPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "app", !isCloudPlaceholder(url),
              Self.isInSearchRoot(path, roots: applicationRoots),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isValidBundleID(_ id: String) -> Bool {
        id.split(separator: ".").count >= 2 && id.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
            && !id.contains("..")
    }

    private static func isUninstallableBundleID(_ id: String) -> Bool {
        isValidBundleID(id) && !id.lowercased().hasPrefix("com.apple.")
            && id.caseInsensitiveCompare("com.tebo.app") != .orderedSame
    }

    private static func isRunning(_ id: String, in identifiers: Set<String>) -> Bool {
        identifiers.contains {
            $0.caseInsensitiveCompare(id) == .orderedSame || $0.lowercased().hasPrefix(id.lowercased() + ".")
        }
    }
}
