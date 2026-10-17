import Foundation

// MARK: - OrphanScanner
// Orphaned-app leftover discovery, ported from Mole's orphan scan
// (lib/clean/apps.sh is_bundle_orphaned:452-526, clean_orphaned_app_data:651-893)
// and its leftover expansion (lib/core/app_protection.sh find_app_files:960-1045).
// This scanner FINDS and REPORTS only; nothing here can delete, and nothing
// here feeds a delete path - the app's DeletePipeline is the only place
// files may be removed.
//
// Verdicts are deliberately conservative:
// - Only reverse-DNS cache owners in the explicit rebuildable-owner policy
//   can be considered, and only after a complete negative ownership lookup.
// - Application Support, Preferences and LaunchAgents remain read-only user
//   state; missing app ownership never makes them disposable.
// - Every system, security-sensitive, unsupported CLI, protected or unknown
//   owner is kept; no generic-name or wildcard cache fallback exists.

// MARK: Models

/// Where a leftover row was found.
public enum OrphanCategory: String, Sendable, Equatable, CaseIterable {
    case applicationSupport = "Application Support"
    case caches = "Caches"
    case preferences = "Preferences"
    case launchAgent = "Launch Agent"
}

/// One leftover that looks orphaned. The UI shows these; if the user
/// approves, `path` feeds DeletePipeline like any other scan row.
public struct OrphanRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    /// Best-effort size. When `isSizeComplete` is false this is a LOWER
    /// BOUND: the walk hit its entry budget or deadline before finishing,
    /// and the UI must not present it as an exact number.
    public let sizeBytes: Int64
    /// false = the size walk was cut short, so `sizeBytes` is a lower
    /// bound, not the real total.
    public let isSizeComplete: Bool
    public let lastModified: Date?
    public let category: OrphanCategory
    /// Why this looks orphaned, e.g. "No installed app owns bundle id
    /// com.foo.bar".
    public let reason: String

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        sizeBytes: Int64,
        isSizeComplete: Bool = true,
        lastModified: Date?,
        category: OrphanCategory,
        reason: String
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.isSizeComplete = isSizeComplete
        self.lastModified = lastModified
        self.category = category
        self.reason = reason
    }

    public var displaySize: String {
        guard isSizeComplete else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// An entry the scanner deliberately kept. Returned so the UI can explain
/// WHY something was not offered for removal - the conservative contract
/// is observable, not silent.
public struct OrphanKeptRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let reason: String

    public init(id: UUID = UUID(), name: String, path: String, reason: String) {
        self.id = id
        self.name = name
        self.path = path
        self.reason = reason
    }
}

public struct OrphanScanReport: Sendable, Equatable {
    public let orphans: [OrphanRow]
    public let kept: [OrphanKeptRow]

    public var itemCount: Int { orphans.count }
    /// Sum of the measured sizes; rows whose walk was cut short contribute
    /// their lower-bound value here, same as they show in the list.
    public var totalBytes: Int64 { orphans.reduce(0) { $0 + $1.sizeBytes } }
    public var displayTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    public init(orphans: [OrphanRow], kept: [OrphanKeptRow]) {
        self.orphans = orphans
        self.kept = kept
    }
}

// MARK: Configuration

public struct OrphanScanConfiguration: Sendable, Equatable {
    /// Roots whose direct children are checked for leftovers.
    public var applicationSupportRoots: [String]
    public var cacheRoots: [String]
    public var preferenceRoots: [String]
    public var launchAgentRoots: [String]
    /// Roots searched for installed .app bundles (ownership evidence).
    public var applicationRoots: [String]
    /// Mole's 30-day orphan age gate (apps.sh:485-493,
    /// ORPHAN_AGE_THRESHOLD): anything modified inside this window is
    /// kept. Seconds; 0 disables the gate (fixture mode).
    public var minimumOrphanAge: TimeInterval
    /// Exact bundle IDs whose cache-only disposable semantics have been
    /// explicitly reviewed. Empty by default: a missing app alone is not
    /// evidence that user data is disposable.
    public var rebuildableCacheBundleIDs: Set<String>
    /// Row cap per verdict list, like the app's other scan caps.
    public var maximumRowsPerVerdict: Int
    /// Entry budget for recursive size measurement of a confirmed orphan
    /// directory. A pathological tree (huge app bundle, mount point) must
    /// not run the walk away: past this many entries the size is reported
    /// as nil so the UI shows "unavailable" instead of a wrong number.
    public var sizeWalkEntryBudget: Int

    public init(
        applicationSupportRoots: [String],
        cacheRoots: [String],
        preferenceRoots: [String],
        launchAgentRoots: [String],
        applicationRoots: [String],
        minimumOrphanAge: TimeInterval = 30 * 24 * 60 * 60,
        rebuildableCacheBundleIDs: Set<String> = [],
        maximumRowsPerVerdict: Int = 500,
        sizeWalkEntryBudget: Int = 200_000
    ) {
        self.applicationSupportRoots = applicationSupportRoots
        self.cacheRoots = cacheRoots
        self.preferenceRoots = preferenceRoots
        self.launchAgentRoots = launchAgentRoots
        self.applicationRoots = applicationRoots
        self.minimumOrphanAge = minimumOrphanAge
        self.rebuildableCacheBundleIDs = Set(rebuildableCacheBundleIDs.map { $0.lowercased() })
        self.maximumRowsPerVerdict = maximumRowsPerVerdict
        self.sizeWalkEntryBudget = sizeWalkEntryBudget
    }

    /// User-scoped defaults, mirroring Mole's user-level orphan scan
    /// (apps.sh:779-782 uses $HOME/Library). System-level roots can be
    /// added explicitly; they are not defaults because root-owned trees
    /// are mostly TCC noise for a user-facing scan.
    public static func defaults(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> OrphanScanConfiguration {
        let h = home as NSString
        func joined(_ relative: String) -> String { h.appendingPathComponent(relative) }
        return OrphanScanConfiguration(
            applicationSupportRoots: [joined("Library/Application Support")],
            cacheRoots: [joined("Library/Caches")],
            preferenceRoots: [joined("Library/Preferences")],
            launchAgentRoots: [joined("Library/LaunchAgents")],
            applicationRoots: ["/Applications", joined("Applications")],
            minimumOrphanAge: 30 * 24 * 60 * 60,
            maximumRowsPerVerdict: 500
        )
    }
}

// MARK: Bundle lookup

public enum BundleLookupResult: Sendable, Equatable {
    case installed
    case notInstalled
    case unknown
}

/// Ownership probe seam. Tests inject a stub (including one that always
/// answers unknown, to pin the fail-closed behaviour).
public protocol BundleLookup: Sendable {
    func isInstalled(bundleID: String) async -> BundleLookupResult
    /// Bypasses memoized negative results and refreshes the configured app inventory.
    func isInstalledFresh(bundleID: String) async -> BundleLookupResult
}

public extension BundleLookup {
    func isInstalledFresh(bundleID: String) async -> BundleLookupResult {
        // A lookup that cannot refresh its state is not evidence of absence.
        .unknown
    }
}

/// Default lookup: an installed-bundle scan over the app roots plus Mole's
/// mdfind fallback for ids the roots do not contain (apps.sh:495-522).
public struct InstalledAppsBundleLookup: BundleLookup {
    private let cache: BundleIDCache

    /// - Parameters:
    ///   - appRoots: directories scanned for installed .app bundles.
    ///   - useSpotlightFallback: run the bounded mdfind probe for ids the
    ///     roots do not contain. Disable in tests/fixtures so no real
    ///     Spotlight query runs.
    public init(appRoots: [String], useSpotlightFallback: Bool = true) {
        self.cache = BundleIDCache(appRoots: appRoots, useSpotlight: useSpotlightFallback)
    }

    public func isInstalled(bundleID: String) async -> BundleLookupResult {
        await cache.lookup(bundleID)
    }

    public func isInstalledFresh(bundleID: String) async -> BundleLookupResult {
        await cache.lookupFresh(bundleID)
    }
}

/// Memoized discovery lookup plus an explicit fresh lookup for final policy checks.
actor BundleIDCache {
    private var results: [String: BundleLookupResult] = [:]
    private var rootIndex: InstalledAppIndex?
    private let appRoots: [String]
    private let useSpotlight: Bool

    init(appRoots: [String], useSpotlight: Bool) {
        self.appRoots = appRoots
        self.useSpotlight = useSpotlight
    }

    func lookup(_ bundleID: String) async -> BundleLookupResult {
        let key = bundleID.lowercased()
        if let cached = results[key] { return cached }
        let index = rootIndex ?? InstalledAppIndex.build(from: appRoots)
        rootIndex = index
        if index.bundleIDs.contains(key) {
            results[key] = .installed
            return .installed
        }
        let result: BundleLookupResult
        if useSpotlight {
            let spotlight = await spotlightLookup(bundleID: bundleID)
            result = spotlight == .notInstalled && !index.isComplete ? .unknown : spotlight
        } else {
            result = index.isComplete ? .notInstalled : .unknown
        }
        if result != .unknown { results[key] = result }
        return result
    }

    /// Always rebuild the configured installed-app index and never reuse a
    /// negative Spotlight result. A new app installed after preview therefore
    /// cannot be hidden by the scan-time absence cache.
    func lookupFresh(_ bundleID: String) async -> BundleLookupResult {
        let index = InstalledAppIndex.build(from: appRoots)
        if index.bundleIDs.contains(bundleID.lowercased()) { return .installed }
        if useSpotlight {
            let spotlight = await spotlightLookup(bundleID: bundleID)
            if spotlight == .installed { return .installed }
            guard index.isComplete else { return .unknown }
            return spotlight
        }
        return index.isComplete ? .notInstalled : .unknown
    }

    /// Mole's mdfind probe (apps.sh:510): empty output is useful only on a
    /// successful, untruncated process. Timeout, error or truncated output is
    /// unknown, never evidence of absence.
    private func spotlightLookup(bundleID: String) async -> BundleLookupResult {
        let result = await BoundedProcessRunner.run(
            executablePath: "/usr/bin/mdfind",
            arguments: ["kMDItemCFBundleIdentifier == '\(bundleID)'"],
            timeout: 5
        )
        return InstalledAppsBundleLookup.spotlightResult(
            terminationStatus: result.terminationStatus,
            stdout: result.stdout,
            outputTruncated: result.outputTruncated
        )
    }
}

extension InstalledAppsBundleLookup {
    static func spotlightResult(
        terminationStatus: Int32?, stdout: String, outputTruncated: Bool
    ) -> BundleLookupResult {
        guard terminationStatus == 0, !outputTruncated else { return .unknown }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .notInstalled : .installed
    }
}

// MARK: Installed-app evidence

/// Snapshot of the installed apps used to attribute leftovers, built from
/// the configured app roots (Mole's installed-bundles scan,
/// lib/clean/apps.sh scan_installed_apps:243-407).
struct InstalledAppIndex: Sendable, Equatable {
    /// Lowercased bundle ids present in the app roots.
    let bundleIDs: Set<String>
    /// Lowercased name variant -> display name of the owning app.
    let variantOwners: [String: String]
    /// False when any configured root or app identity could not be fully read.
    let isComplete: Bool

    static func build(from roots: [String]) -> InstalledAppIndex {
        var bundleIDs: Set<String> = []
        var variantOwners: [String: String] = [:]
        var complete = !roots.isEmpty
        let fm = FileManager.default
        let deadline = Date.now.addingTimeInterval(8)
        var remainingEntries = 100_000

        for root in roots {
            guard !Task.isCancelled, Date.now < deadline else {
                complete = false
                break
            }
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            var rootIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: rootURL.path, isDirectory: &rootIsDirectory) else {
                if !confirmedMissingRoot(rootURL, fileManager: fm) { complete = false }
                continue
            }
            guard rootIsDirectory.boolValue,
                  let rootValues = try? rootURL.resourceValues(forKeys: [.isSymbolicLinkKey, .volumeIsLocalKey]),
                  rootValues.isSymbolicLink != true,
                  rootValues.volumeIsLocal == true else {
                complete = false
                continue
            }

            var pending: [(url: URL, depth: Int)] = [(rootURL, 0)]
            while let (directory, depth) = pending.popLast() {
                guard !Task.isCancelled, Date.now < deadline, remainingEntries > 0 else {
                    complete = false
                    break
                }
                guard let children = try? fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey],
                    options: []
                ) else {
                    complete = false
                    continue
                }
                for child in children {
                    remainingEntries -= 1
                    guard remainingEntries >= 0,
                          let values = try? child.resourceValues(
                            forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey]
                          ) else {
                        complete = false
                        continue
                    }
                    guard values.volumeIsLocal == true else {
                        complete = false
                        continue
                    }
                    let isBundle = child.pathExtension.lowercased() == "app"
                    if values.isSymbolicLink == true {
                        guard isBundle else { complete = false; continue }
                        let resolved = child.resolvingSymlinksInPath()
                        guard let info = readBundleInfo(at: resolved.path),
                              let id = info.bundleID, !id.isEmpty else {
                            complete = false
                            continue
                        }
                        record(info, folderName: resolved.deletingPathExtension().lastPathComponent,
                               bundleID: id, bundleIDs: &bundleIDs, variantOwners: &variantOwners)
                        continue
                    }
                    guard values.isDirectory == true else { continue }
                    if isBundle {
                        guard let info = readBundleInfo(at: child.path),
                              let id = info.bundleID, !id.isEmpty else {
                            complete = false
                            continue
                        }
                        record(info, folderName: child.deletingPathExtension().lastPathComponent,
                               bundleID: id, bundleIDs: &bundleIDs, variantOwners: &variantOwners)
                    } else if depth < 64 {
                        pending.append((child, depth + 1))
                    } else {
                        complete = false
                    }
                }
            }
        }
        return InstalledAppIndex(bundleIDs: bundleIDs, variantOwners: variantOwners, isComplete: complete)
    }

    private static func record(
        _ info: BundleInfo,
        folderName: String,
        bundleID: String,
        bundleIDs: inout Set<String>,
        variantOwners: inout [String: String]
    ) {
        bundleIDs.insert(bundleID.lowercased())
        var names: [String] = [folderName]
        if let leaf = bundleID.split(separator: ".").last { names.append(String(leaf)) }
        if let name = info.name { names.append(name) }
        if let displayName = info.displayName { names.append(displayName) }
        if let executable = info.executable { names.append(executable) }
        let display = info.displayName ?? info.name ?? folderName
        for candidate in names where !candidate.isEmpty {
            for variant in nameVariants(of: candidate) where !variant.isEmpty {
                if variantOwners[variant] == nil { variantOwners[variant] = display }
            }
        }
    }

    private static func confirmedMissingRoot(_ root: URL, fileManager: FileManager) -> Bool {
        let parent = root.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path),
              let children = try? fileManager.contentsOfDirectory(atPath: parent.path) else { return false }
        return !children.contains(root.lastPathComponent)
    }

    /// The installed app whose naming variants match childName, or nil.
    /// Case-insensitive because default APFS volumes are (batch.sh:657-667).
    func matchingInstalledApp(childName: String) -> String? {
        variantOwners[childName.lowercased()]
    }

    /// Mole's naming variants (app_protection.sh:981-996): the name
    /// itself, its no-space / underscore / hyphen forms, and the base name
    /// with version-channel suffixes stripped. All lowercased.
    static func nameVariants(of name: String) -> Set<String> {
        var out: Set<String> = []
        out.insert(name.lowercased())
        out.insert(name.replacingOccurrences(of: " ", with: "").lowercased())
        out.insert(name.replacingOccurrences(of: " ", with: "_").lowercased())
        out.insert(name.replacingOccurrences(of: " ", with: "-").lowercased())
        let channelSuffixes: Set<String> = [
            "nightly", "beta", "alpha", "dev", "canary", "preview", "insider",
            "edge", "stable", "release", "rc", "lts",
        ]
        let words = name.split(separator: " ")
        if words.count > 1, let last = words.last,
           channelSuffixes.contains(last.lowercased()) {
            out.formUnion(nameVariants(of: words.dropLast().joined(separator: " ")))
        }
        // Mole's two multi-word channel suffixes (app_protection.sh:992-993).
        let lower = name.lowercased()
        for suffix in [" developer edition", " technology preview"] where lower.hasSuffix(suffix) {
            out.formUnion(nameVariants(of: String(name.dropLast(suffix.count))))
        }
        return out
    }

    private static func readBundleInfo(at appPath: String) -> BundleInfo? {
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return BundleInfo(
            bundleID: plist["CFBundleIdentifier"] as? String,
            name: plist["CFBundleName"] as? String,
            displayName: plist["CFBundleDisplayName"] as? String,
            executable: plist["CFBundleExecutable"] as? String
        )
    }
}

struct BundleInfo {
    let bundleID: String?
    let name: String?
    let displayName: String?
    let executable: String?
}

struct CacheTreeInspection {
    let sizeBytes: Int64
    let newestModification: Date?
    let protectionReason: String?
}

// MARK: Scanner

/// The finder the Apps/Disk tab calls. Injectable configuration (fixture
/// roots) and bundle lookup (stub probes) keep tests off the real machine.
public struct OrphanScanner: Sendable {
    public let configuration: OrphanScanConfiguration
    private let bundleLookup: any BundleLookup

    public init(
        configuration: OrphanScanConfiguration = .defaults(),
        bundleLookup: (any BundleLookup)? = nil
    ) {
        self.configuration = configuration
        self.bundleLookup = bundleLookup
            ?? InstalledAppsBundleLookup(appRoots: configuration.applicationRoots)
    }

    enum OrphanVerdict {
        /// Why it looks orphaned plus its mtime; the row is built after
        /// sizing so big trees are only measured once a candidate is
        /// confirmed (Mole sizes after the orphan check, apps.sh:851).
        case orphan(reason: String, lastModified: Date?, tree: CacheTreeInspection?)
        case keep(OrphanKeptRow)
    }

    public func scan(whitelist: Set<String> = []) async -> OrphanScanReport {
        var orphans: [OrphanRow] = []
        var kept: [OrphanKeptRow] = []
        let index = InstalledAppIndex.build(from: configuration.applicationRoots)
        let now = Date()
        let cap = configuration.maximumRowsPerVerdict

        // Sizing happens only AFTER a verdict confirms an orphan (Mole
        // sizes after the orphan check, apps.sh:851): recursive measuring
        // of every child of Application Support/Caches would walk
        // multi-GB live app trees for nothing.
        func collect(
            _ verdict: OrphanVerdict,
            name: String,
            path: String,
            category: OrphanCategory,
            fileSize: Int64,
            isDirectory: Bool
        ) {
            switch verdict {
            case .orphan(let reason, let lastModified, let tree):
                guard orphans.count < cap else { return }
                if isDirectory {
                    let sizeBytes: Int64
                    let isComplete: Bool
                    if let tree {
                        sizeBytes = tree.sizeBytes
                        isComplete = true
                    } else {
                        let measured = Self.recursiveSize(
                            at: path, entryBudget: configuration.sizeWalkEntryBudget
                        )
                        sizeBytes = measured.bytes
                        isComplete = measured.complete
                    }
                    guard sizeBytes > 0 else { return }
                    orphans.append(OrphanRow(
                        name: name, path: path, sizeBytes: sizeBytes,
                        isSizeComplete: isComplete,
                        lastModified: tree?.newestModification ?? lastModified,
                        category: category, reason: reason
                    ))
                } else {
                    // Zero-size leftovers are skipped like Mole's size gate
                    // (apps.sh:856): nothing reclaimable, nothing reported.
                    guard fileSize > 0 else { return }
                    orphans.append(OrphanRow(
                        name: name, path: path, sizeBytes: fileSize,
                        lastModified: lastModified, category: category, reason: reason
                    ))
                }
            case .keep(let row):
                if kept.count < cap { kept.append(row) }
            }
        }

        // Application Support is surfaced as read-only personal data; only
        // explicitly supported direct Caches children can reach orphan policy.
        let directoryCategories: [([String], OrphanCategory)] = [
            (configuration.applicationSupportRoots, .applicationSupport),
            (configuration.cacheRoots, .caches),
        ]
        for (roots, category) in directoryCategories {
            for root in roots {
                guard !Task.isCancelled else { break }
                guard let children = Self.directChildren(of: root) else { continue }
                for child in children {
                    if Task.isCancelled || (orphans.count >= cap && kept.count >= cap) { break }
                    if let reason = child.protectionReason {
                        collect(
                            .keep(OrphanKeptRow(name: child.name, path: child.url.path, reason: reason)),
                            name: child.name, path: child.url.path, category: category,
                            fileSize: child.sizeBytes, isDirectory: child.isDirectory
                        )
                        continue
                    }
                    if child.name.hasPrefix(".") {
                        collect(
                            .keep(OrphanKeptRow(name: child.name, path: child.url.path,
                                reason: "Dot-prefixed user and command-line state is kept")),
                            name: child.name, path: child.url.path, category: category,
                            fileSize: child.sizeBytes, isDirectory: child.isDirectory
                        )
                        continue
                    }
                    let verdict: OrphanVerdict
                    if category == .caches {
                        if !child.isDirectory {
                            verdict = .keep(OrphanKeptRow(
                                name: child.name, path: child.url.path,
                                reason: "Cache candidate is not a directory; kept"
                            ))
                        } else {
                            verdict = await classify(
                                name: child.name,
                                evidenceName: child.name,
                                path: child.url.path,
                                whitelist: whitelist,
                                lastModified: child.modified,
                                index: index,
                                now: now
                            )
                        }
                    } else {
                        verdict = .keep(OrphanKeptRow(
                            name: child.name, path: child.url.path,
                            reason: "Application Support is personal app data and remains read-only"
                        ))
                    }
                    collect(
                        verdict,
                        name: child.name,
                        path: child.url.path,
                        category: category,
                        fileSize: child.sizeBytes,
                        isDirectory: child.isDirectory
                    )
                }
            }
        }

        // Preferences: only top-level .plist files. ByHost is a directory
        // and never reaches the file filter (AGENTS.md: skip broad
        // locations like Preferences/ByHost).
        for root in configuration.preferenceRoots {
            guard !Task.isCancelled else { break }
            guard let children = Self.directChildren(of: root) else { continue }
            for child in children {
                if Task.isCancelled || (orphans.count >= cap && kept.count >= cap) { break }
                if let reason = child.protectionReason {
                    collect(
                        .keep(OrphanKeptRow(name: child.name, path: child.url.path, reason: reason)),
                        name: child.name, path: child.url.path, category: .preferences,
                        fileSize: child.sizeBytes, isDirectory: child.isDirectory
                    )
                    continue
                }
                guard !child.isDirectory, child.name.hasSuffix(".plist") else { continue }
                let stem = (child.name as NSString).deletingPathExtension
                guard !stem.isEmpty else { continue }
                let verdict = OrphanVerdict.keep(OrphanKeptRow(
                    name: child.name, path: child.url.path,
                    reason: "Preferences are personal user state and remain read-only"
                ))
                collect(
                    verdict,
                    name: child.name,
                    path: child.url.path,
                    category: .preferences,
                    fileSize: child.sizeBytes,
                    isDirectory: false
                )
            }
        }

        // LaunchAgents: user-owned automation remains read-only regardless of
        // whether its current label or Program target appears installed.
        for root in configuration.launchAgentRoots {
            guard !Task.isCancelled else { break }
            guard let children = Self.directChildren(of: root) else { continue }
            for child in children {
                if Task.isCancelled || (orphans.count >= cap && kept.count >= cap) { break }
                if let reason = child.protectionReason {
                    collect(
                        .keep(OrphanKeptRow(name: child.name, path: child.url.path, reason: reason)),
                        name: child.name, path: child.url.path, category: .launchAgent,
                        fileSize: child.sizeBytes, isDirectory: child.isDirectory
                    )
                    continue
                }
                guard !child.isDirectory, child.name.hasSuffix(".plist") else { continue }
                let verdict = OrphanVerdict.keep(OrphanKeptRow(
                    name: child.name, path: child.url.path,
                    reason: "LaunchAgents are user-owned automation and remain read-only"
                ))
                collect(
                    verdict,
                    name: child.name,
                    path: child.url.path,
                    category: .launchAgent,
                    fileSize: child.sizeBytes,
                    isDirectory: false
                )
            }
        }

        // Biggest first, like the rest of the app's scan rows.
        return OrphanScanReport(
            orphans: orphans.sorted { $0.sizeBytes > $1.sizeBytes },
            kept: kept
        )
    }

    /// The shared conservative gate, mirroring is_bundle_orphaned's order
    /// (apps.sh:452-526): protection list, sensitive names, then the age
    /// gate, then installed-bundle evidence (roots + mdfind fallback).
    private func classify(
        name: String,
        evidenceName: String,
        path: String,
        whitelist: Set<String>,
        lastModified: Date?,
        index: InstalledAppIndex,
        now: Date
    ) async -> OrphanVerdict {
        if Self.isAppleSystemName(evidenceName) {
            return .keep(OrphanKeptRow(
                name: name, path: path,
                reason: "Apple system component; never offered as a leftover"
            ))
        }
        if Self.isSensitiveName(evidenceName) {
            return .keep(OrphanKeptRow(
                name: name, path: path,
                reason: "Security-sensitive name; never treated as disposable cache data"
            ))
        }
        if !SafetyGate.isAllowed(path: path, whitelist: whitelist) {
            return .keep(OrphanKeptRow(name: name, path: path,
                reason: "SafetyGate or user whitelist protects this cache path"))
        }
        if !Self.isBundleIDCandidate(evidenceName)
            || !configuration.rebuildableCacheBundleIDs.contains(evidenceName.lowercased()) {
            return .keep(OrphanKeptRow(
                name: name, path: path,
                reason: "No explicit supported cache-owner policy; kept"
            ))
        }
        guard index.isComplete else {
            return .keep(OrphanKeptRow(name: name, path: path,
                reason: "Installed-app inventory is incomplete; kept"))
        }
        if index.bundleIDs.contains(evidenceName.lowercased()) {
            return .keep(OrphanKeptRow(name: name, path: path,
                reason: "Owned by an installed app (\(evidenceName))"))
        }
        if let lastModified, now.timeIntervalSince(lastModified) < configuration.minimumOrphanAge {
            return .keep(OrphanKeptRow(
                name: name, path: path,
                reason: "Modified within the retention window; the app may still be in use"
            ))
        }
        if Self.isBundleIDCandidate(evidenceName) {
            switch await bundleLookup.isInstalled(bundleID: evidenceName) {
            case .installed:
                return .keep(OrphanKeptRow(
                    name: name, path: path,
                    reason: "Owned by an installed app (\(evidenceName))"
                ))
            case .unknown:
                // Mole keeps the candidate when the probe times out or
                // errors (apps.sh:511-514); a transient Spotlight stall
                // must not orphan a live app's data.
                return .keep(OrphanKeptRow(
                    name: name, path: path,
                    reason: "Bundle lookup unavailable; kept"
                ))
            case .notInstalled:
                let tree = Self.inspectCacheTree(
                    at: path,
                    entryBudget: configuration.sizeWalkEntryBudget,
                    minimumAge: configuration.minimumOrphanAge,
                    whitelist: whitelist,
                    now: now
                )
                if let reason = tree.protectionReason {
                    return .keep(OrphanKeptRow(name: name, path: path, reason: reason))
                }
                guard tree.newestModification != nil, tree.sizeBytes > 0 else {
                    return .keep(OrphanKeptRow(name: name, path: path,
                        reason: "Cache tree has no complete, positive-size evidence; kept"))
                }
                return .orphan(
                    reason: "Supported cache owner is absent and the complete tree is outside the retention window",
                    lastModified: tree.newestModification,
                    tree: tree
                )
            }
        }
        // Non-bundle-id names: Mole's orphan scan never flags them
        // (apps.sh:779-782 only globs com./org./net./io.); name-based
        // removal exists only in the active-uninstall flow where an app is
        // known to be going away. Anything else could be a command-line
        // tool's data or a system component, so it is kept.
        if let owner = index.matchingInstalledApp(childName: evidenceName) {
            return .keep(OrphanKeptRow(
                name: name, path: path,
                reason: "Owned by installed app \(owner)"
            ))
        }
        return .keep(OrphanKeptRow(
            name: name, path: path,
            reason: "No bundle identifier; may belong to a system component or a command-line tool"
        ))
    }

    private static func inspectCacheTree(
        at path: String,
        entryBudget: Int,
        minimumAge: TimeInterval,
        whitelist: Set<String>,
        now: Date
    ) -> CacheTreeInspection {
        func rejected(_ reason: String, newest: Date? = nil, bytes: Int64 = 0) -> CacheTreeInspection {
            CacheTreeInspection(sizeBytes: bytes, newestModification: newest, protectionReason: reason)
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .volumeIsLocalKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        var pending = [root]
        var newest: Date?
        var bytes: Int64 = 0
        var entries = 0
        let deadline = now.addingTimeInterval(30)

        while let entry = pending.popLast() {
            guard !Task.isCancelled, Date.now < deadline, entries < entryBudget else {
                return rejected("Cache tree traversal is incomplete; kept", newest: newest, bytes: bytes)
            }
            entries += 1
            guard SafetyGate.isAllowed(path: entry.path, whitelist: whitelist),
                  let values = try? entry.resourceValues(forKeys: keys) else {
                return rejected("SafetyGate protection or missing cache-tree metadata; kept",
                                newest: newest, bytes: bytes)
            }
            guard values.isSymbolicLink != true else {
                return rejected("Cache tree contains a symlink; kept", newest: newest, bytes: bytes)
            }
            guard values.volumeIsLocal == true else {
                return rejected("Cache tree contains non-local or unknown-volume data; kept",
                                newest: newest, bytes: bytes)
            }
            guard values.isUbiquitousItem != true,
                  values.ubiquitousItemDownloadingStatus == nil else {
                return rejected("Cache tree contains cloud-backed data; kept", newest: newest, bytes: bytes)
            }
            guard let modified = values.contentModificationDate else {
                return rejected("Cache tree modification metadata is unknown; kept", newest: newest, bytes: bytes)
            }
            newest = max(newest ?? modified, modified)
            guard now.timeIntervalSince(modified) >= minimumAge else {
                return rejected("A cache-tree descendant is inside the retention window; kept",
                                newest: newest, bytes: bytes)
            }
            if values.isDirectory == true {
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: Array(keys), options: []
                ) else {
                    return rejected("Cache tree contains an unreadable directory; kept",
                                    newest: newest, bytes: bytes)
                }
                pending.append(contentsOf: children)
            } else if values.isRegularFile == true, let size = values.fileSize, size >= 0 {
                let (updatedBytes, overflow) = bytes.addingReportingOverflow(Int64(size))
                guard !overflow else {
                    return rejected("Cache tree size exceeded measurable bounds; kept",
                                    newest: newest, bytes: bytes)
                }
                bytes = updatedBytes
            } else {
                return rejected("Cache tree contains a non-regular or unmeasurable entry; kept",
                                newest: newest, bytes: bytes)
            }
        }
        guard entries > 0 else { return rejected("Cache tree evidence is unavailable; kept") }
        return CacheTreeInspection(sizeBytes: bytes, newestModification: newest, protectionReason: nil)
    }

    /// Re-evaluates an exact direct cache child against current configuration,
    /// installed inventory, Spotlight and every descendant. nil means only that
    /// this narrow discovery policy still holds, not that removal is authorized.
    public func removalProtectionReason(for path: String, whitelist: Set<String>) async -> String? {
        guard SafetyGate.isAllowed(path: path, whitelist: whitelist) else {
            return "SafetyGate or user whitelist protects this cache path"
        }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let candidateParent = candidate.deletingLastPathComponent().standardizedFileURL.path
        let configuredRoot = configuration.cacheRoots.first { root in
            let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
            let lexicalPath = rootURL.path
            let physicalPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            return candidateParent == lexicalPath || candidateParent == physicalPath
        }
        guard let configuredRoot,
              (try? URL(fileURLWithPath: configuredRoot, isDirectory: true)
                .resourceValues(forKeys: [.isSymbolicLinkKey, .volumeIsLocalKey]).isSymbolicLink) != true,
              (try? URL(fileURLWithPath: configuredRoot, isDirectory: true)
                .resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else {
            return "Path is not a direct child of a local configured cache root"
        }
        guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else {
            return "Cache path is missing, linked, or not a directory"
        }
        let owner = candidate.lastPathComponent
        guard Self.isBundleIDCandidate(owner),
              configuration.rebuildableCacheBundleIDs.contains(owner.lowercased()),
              !Self.isAppleSystemName(owner), !Self.isSensitiveName(owner) else {
            return "No explicit supported cache-owner policy; kept"
        }
        let index = InstalledAppIndex.build(from: configuration.applicationRoots)
        guard index.isComplete else { return "Installed-app inventory is incomplete; kept" }
        if index.bundleIDs.contains(owner.lowercased()) {
            return "Owned by an installed app (\(owner))"
        }
        switch await bundleLookup.isInstalledFresh(bundleID: owner) {
        case .installed:
            return "Owned by an installed app (\(owner))"
        case .unknown:
            return "Fresh bundle lookup unavailable or incomplete; kept"
        case .notInstalled:
            break
        }
        return Self.inspectCacheTree(
            at: candidate.path,
            entryBudget: configuration.sizeWalkEntryBudget,
            minimumAge: configuration.minimumOrphanAge,
            whitelist: whitelist,
            now: Date.now
        ).protectionReason
    }

    // MARK: Name rules

    /// Mole's hardcoded system components (apps.sh:478-482) plus the
    /// com.apple.* blanket guard AGENTS.md requires.
    static func isAppleSystemName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("com.apple.") { return true }
        let hardcoded: Set<String> = [
            "loginwindow", "dock", "systempreferences", "systemsettings",
            "settings", "controlcenter", "finder", "safari",
        ]
        return hardcoded.contains(lower)
    }

    /// Mole's ORPHAN_NEVER_DELETE_PATTERNS (apps.sh:410-420), lowered and
    /// matched by containment like the case globs.
    static func isSensitiveName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let patterns = [
            "1password", "keychain", "bitwarden", "lastpass", "keepass",
            "dashlane", "enpass", "ssh", "gpg", "gnupg",
        ]
        return patterns.contains { lower.contains($0) }
    }

    /// Mole mole_is_reverse_dns_bundle_id (lib/core/base.sh:814-819)
    /// restricted to the domain prefixes Mole's orphan scan actually globs
    /// (com./org./net./io., apps.sh:780) - a dotted name like "1.2.3"
    /// never becomes a bundle-id probe.
    static func isBundleIDCandidate(_ name: String) -> Bool {
        let prefixes = ["com.", "org.", "net.", "io."]
        guard prefixes.contains(where: { name.lowercased().hasPrefix($0) }) else {
            return false
        }
        let pattern = #"^[A-Za-z0-9][-A-Za-z0-9]*(\.[A-Za-z0-9][-A-Za-z0-9]*)+$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    // MARK: Filesystem helpers

    struct ChildEntry {
        let name: String
        let url: URL
        let isDirectory: Bool
        let sizeBytes: Int64
        let modified: Date?
        let protectionReason: String?
    }

    /// Direct children of a local, non-cloud root. Missing roots are ignored;
    /// unsafe roots and unknown child metadata are represented as kept rows.
    /// Symlinks are never followed.
    static func directChildren(of root: String) -> [ChildEntry]? {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let fileManager = FileManager.default
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &rootIsDirectory) else { return nil }

        func keptRoot(_ reason: String) -> [ChildEntry] {
            [ChildEntry(
                name: rootURL.lastPathComponent, url: rootURL,
                isDirectory: rootIsDirectory.boolValue, sizeBytes: 0, modified: nil,
                protectionReason: reason
            )]
        }
        guard rootIsDirectory.boolValue else { return keptRoot("Scan root is not a directory; kept") }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            .volumeIsLocalKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let rootValues = try? rootURL.resourceValues(forKeys: keys) else {
            return keptRoot("Scan root metadata is unavailable; kept")
        }
        guard rootValues.isSymbolicLink != true else { return keptRoot("Scan root is linked; kept") }
        guard rootValues.volumeIsLocal == true, rootValues.isUbiquitousItem != true,
              rootValues.ubiquitousItemDownloadingStatus == nil else {
            return keptRoot("Scan root is cloud-backed, non-local, or unknown; kept")
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: Array(keys), options: []
        ) else { return keptRoot("Scan root is unreadable; kept") }
        return children.map { child in
            guard let values = try? child.resourceValues(forKeys: keys) else {
                return ChildEntry(
                    name: child.lastPathComponent, url: child, isDirectory: false,
                    sizeBytes: 0, modified: nil,
                    protectionReason: "Entry metadata is unavailable; kept"
                )
            }
            if values.isSymbolicLink == true {
                return ChildEntry(
                    name: child.lastPathComponent, url: child, isDirectory: false,
                    sizeBytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate,
                    protectionReason: "Symlink entry is kept without following it"
                )
            }
            return ChildEntry(
                name: child.lastPathComponent,
                url: child,
                isDirectory: values.isDirectory ?? false,
                sizeBytes: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate,
                protectionReason: nil
            )
        }
    }

    /// Outcome of a bounded size walk.
    struct SizeWalkResult {
        let bytes: Int64
        /// false = cut short by the entry budget or the deadline, so
        /// `bytes` is a lower bound.
        let complete: Bool
    }

    /// Recursive folder size, symlink-safe and error-tolerant (same rules
    /// as CleanerService.recursiveSize): never follows directory symlinks,
    /// unreadable subtrees are skipped. Three hard bounds so a
    /// pathological tree cannot run the walk away: a wall-clock deadline
    /// (like Mole's timeout-bounded get_path_size_kb probes), an entry
    /// budget (marks the result incomplete, never an under-measured
    /// number presented as exact), and a locality guard - subtrees on
    /// non-local volumes (network shares, mounted disk images) are never
    /// descended into, because those bytes are not reclaimable leftovers
    /// and the walk could cross into a remote filesystem.
    static func recursiveSize(at path: String, entryBudget: Int) -> SizeWalkResult {
        let deadline = Date().addingTimeInterval(30)
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return SizeWalkResult(bytes: 0, complete: true)
        }
        if !isDir.boolValue {
            return SizeWalkResult(
                bytes: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                complete: true
            )
        }
        // A non-local root (e.g. an orphaned dir that is itself a network
        // mount) is not measurable local reclaimable space: report zero so
        // the row is dropped by the size gate, never walked.
        if (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false {
            return SizeWalkResult(bytes: 0, complete: true)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey,
            ],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return SizeWalkResult(bytes: 0, complete: true) }

        var total: Int64 = 0
        var seen = 0
        for case let file as URL in enumerator {
            seen += 1
            if seen > entryBudget { return SizeWalkResult(bytes: total, complete: false) }
            if seen % 256 == 0 {
                if Task.isCancelled { break }
                if Date() > deadline { return SizeWalkResult(bytes: total, complete: false) }
            }
            guard let values = try? file.resourceValues(
                forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey]
            ) else { continue }
            if values.isSymbolicLink == true, values.isDirectory == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                // Never descend into mounted/non-local subtrees; bytes
                // there are someone else's volume, not leftover space.
                if values.volumeIsLocal == false {
                    enumerator.skipDescendants()
                }
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return SizeWalkResult(bytes: total, complete: true)
    }
}
