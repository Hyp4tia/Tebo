import Foundation

// MARK: - OrphanScanner
// Orphaned-app leftover discovery, ported from Mole's orphan scan
// (lib/clean/apps.sh is_bundle_orphaned:452-526, clean_orphaned_app_data:651-893)
// and its leftover expansion (lib/core/app_protection.sh find_app_files:960-1045).
// This scanner FINDS and REPORTS only; nothing here can delete, and nothing
// here feeds a delete path - the app's DeletePipeline is the only place
// files may be removed.
//
// Verdicts are deliberately conservative, matching Mole's own surface:
// - Only reverse-DNS bundle ids (com./org./net./io. children, apps.sh:779-782)
//   are ever classified as orphans, and only after a negative bundle lookup.
// - LaunchAgents need a bundle-id label PLUS a missing absolute Program
//   path (AGENTS.md: parse plist Program/ProgramArguments values as
//   absolute paths only).
// - Every name that could be a system component, a security tool, or a
//   command-line tool is kept with a reason (AGENTS.md: leftover matching
//   stays exact; no generic-name or wildcard fallbacks).

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
        maximumRowsPerVerdict: Int = 500,
        sizeWalkEntryBudget: Int = 200_000
    ) {
        self.applicationSupportRoots = applicationSupportRoots
        self.cacheRoots = cacheRoots
        self.preferenceRoots = preferenceRoots
        self.launchAgentRoots = launchAgentRoots
        self.applicationRoots = applicationRoots
        self.minimumOrphanAge = minimumOrphanAge
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
}

/// Default lookup: an installed-bundle scan over the app roots plus Mole's
/// mdfind fallback for apps installed elsewhere (apps.sh:495-522).
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
}

/// Memoized bundle-id resolver. Only installed/notInstalled outcomes are
/// cached: a probe failure is unknown and must NOT be cached, or a
/// transient Spotlight stall would mark a live app as missing for the rest
/// of the process (Mole's poison-the-cache rule, apps.sh:503-507).
actor BundleIDCache {
    private var results: [String: BundleLookupResult] = [:]
    private var rootBundleIDs: Set<String>?
    private let appRoots: [String]
    private let useSpotlight: Bool

    init(appRoots: [String], useSpotlight: Bool) {
        self.appRoots = appRoots
        self.useSpotlight = useSpotlight
    }

    func lookup(_ bundleID: String) async -> BundleLookupResult {
        // Bundle ids are case-PRESERVING but not case-SENSITIVE for the
        // paths apps write (Mole lib/uninstall/batch.sh:657-667).
        let key = bundleID.lowercased()
        if let cached = results[key] { return cached }
        if rootBundleIDs == nil {
            rootBundleIDs = InstalledAppIndex.build(from: appRoots).bundleIDs
        }
        if rootBundleIDs?.contains(key) == true {
            results[key] = .installed
            return .installed
        }
        guard useSpotlight else {
            // Fixture/test mode without Spotlight: absence from the
            // scanned roots is meaningful because the caller owns those
            // roots (a real scan keeps the Spotlight fallback on).
            results[key] = .notInstalled
            return .notInstalled
        }
        let spotlight = await spotlightLookup(bundleID: bundleID)
        if spotlight != .unknown { results[key] = spotlight }
        return spotlight
    }

    /// Mole's mdfind probe (apps.sh:510): absolute path, bounded by
    /// MOLE_TIMEOUT_MEDIUM_PROBE_SEC (5s). Empty output = not installed;
    /// any timeout or error = unknown, which callers keep. Runs through
    /// BoundedProcessRunner, so a hung mdfind is SIGTERM'd at the deadline
    /// and SIGKILL'd 2s later; the await can never block past that.
    private func spotlightLookup(bundleID: String) async -> BundleLookupResult {
        let result = await BoundedProcessRunner.run(
            executablePath: "/usr/bin/mdfind",
            arguments: ["kMDItemCFBundleIdentifier == '\(bundleID)'"],
            timeout: 5
        )
        guard let status = result.terminationStatus else { return .unknown }
        // Watchdog kills surface as terminationStatus 9 (SIGKILL) or 15
        // (SIGTERM); any non-zero status is a probe failure, never an
        // "installed" answer.
        guard status == 0 else { return .unknown }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func build(from roots: [String]) -> InstalledAppIndex {
        var bundleIDs: Set<String> = []
        var variantOwners: [String: String] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let children = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else { continue }
            for child in children {
                guard child.pathExtension.lowercased() == "app" else { continue }
                // Resolve symlinks: a symlinked bundle in ~/Applications is
                // still an installed app and its data must be kept.
                let bundleURL = child.resolvingSymlinksInPath()
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: bundleURL.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                let info = readBundleInfo(at: bundleURL.path)
                let folderName = bundleURL.deletingPathExtension().lastPathComponent
                var names: [String] = [folderName]
                if let id = info.bundleID {
                    bundleIDs.insert(id.lowercased())
                    if let leaf = id.split(separator: ".").last {
                        names.append(String(leaf))
                    }
                }
                if let name = info.name { names.append(name) }
                if let displayName = info.displayName { names.append(displayName) }
                if let executable = info.executable { names.append(executable) }
                let display = info.displayName ?? info.name ?? folderName
                for candidate in names where !candidate.isEmpty {
                    for variant in nameVariants(of: candidate) where !variant.isEmpty {
                        // First app to claim a variant wins; collisions are
                        // rare and either owner keeps the entry, which is
                        // the safe direction.
                        if variantOwners[variant] == nil {
                            variantOwners[variant] = display
                        }
                    }
                }
            }
        }
        return InstalledAppIndex(bundleIDs: bundleIDs, variantOwners: variantOwners)
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

    private static func readBundleInfo(at appPath: String) -> BundleInfo {
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else {
            return BundleInfo(bundleID: nil, name: nil, displayName: nil, executable: nil)
        }
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
        case orphan(reason: String, lastModified: Date?)
        case keep(OrphanKeptRow)
    }

    public func scan() async -> OrphanScanReport {
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
            case .orphan(let reason, let lastModified):
                guard orphans.count < cap else { return }
                if isDirectory {
                    // A cut-short walk reports its lower bound with
                    // isSizeComplete=false so the UI can say "unavailable"
                    // instead of presenting a wrong exact number.
                    let measured = Self.recursiveSize(
                        at: path, entryBudget: configuration.sizeWalkEntryBudget
                    )
                    guard measured.bytes > 0 || !measured.complete else { return }
                    orphans.append(OrphanRow(
                        name: name, path: path, sizeBytes: measured.bytes,
                        isSizeComplete: measured.complete,
                        lastModified: lastModified, category: category, reason: reason
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

        // Application Support + Caches: every direct child is a candidate
        // (Mole's leftover locations, app_protection.sh:1016-1018).
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
                    // Dot-prefixed children are XDG/CLI-style state; Mole
                    // keeps those off blanket cleanup paths by design.
                    if child.name.hasPrefix(".") { continue }
                    let verdict = await classify(
                        name: child.name,
                        evidenceName: child.name,
                        path: child.url.path,
                        lastModified: child.modified,
                        index: index,
                        now: now
                    )
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
                guard !child.isDirectory, child.name.hasSuffix(".plist") else { continue }
                let stem = (child.name as NSString).deletingPathExtension
                guard !stem.isEmpty else { continue }
                let verdict = await classify(
                    name: child.name,
                    evidenceName: stem,
                    path: child.url.path,
                    lastModified: child.modified,
                    index: index,
                    now: now
                )
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

        // LaunchAgents: plist content decides (see classifyLaunchAgent).
        for root in configuration.launchAgentRoots {
            guard !Task.isCancelled else { break }
            guard let children = Self.directChildren(of: root) else { continue }
            for child in children {
                if Task.isCancelled || (orphans.count >= cap && kept.count >= cap) { break }
                guard !child.isDirectory, child.name.hasSuffix(".plist") else { continue }
                let verdict = await classifyLaunchAgent(url: child.url, index: index, now: now)
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
                reason: "Security-sensitive name; Mole never orphans it (apps.sh:410-420)"
            ))
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
                return .orphan(
                    reason: "No installed app owns bundle id \(evidenceName)",
                    lastModified: lastModified
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

    /// LaunchAgent verdict. Mole treats a plist and its Program helper as
    /// one family (AGENTS.md): the plist is only an orphan when its label
    /// is a bundle id with no installed app AND its absolute program path
    /// is gone AND the age gate passes. Everything else is kept with a
    /// reason.
    private func classifyLaunchAgent(
        url: URL,
        index: InstalledAppIndex,
        now: Date
    ) async -> OrphanVerdict {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let lastModified = values?.contentModificationDate

        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else {
            return .keep(OrphanKeptRow(name: name, path: url.path, reason: "Agent plist unreadable; kept"))
        }
        guard let label = plist["Label"] as? String else {
            return .keep(OrphanKeptRow(name: name, path: url.path, reason: "Agent plist has no Label; kept"))
        }
        if Self.isAppleSystemName(label) {
            return .keep(OrphanKeptRow(
                name: name, path: url.path,
                reason: "Apple system agent; never offered as a leftover"
            ))
        }
        if Self.isSensitiveName(label) {
            return .keep(OrphanKeptRow(
                name: name, path: url.path,
                reason: "Security-sensitive agent label; kept"
            ))
        }
        guard Self.isBundleIDCandidate(label) else {
            return .keep(OrphanKeptRow(
                name: name, path: url.path,
                reason: "Agent label \(label) is not a bundle identifier; ownership cannot be proven"
            ))
        }
        switch await bundleLookup.isInstalled(bundleID: label) {
        case .installed:
            return .keep(OrphanKeptRow(
                name: name, path: url.path,
                reason: "Agent belongs to installed app \(label)"
            ))
        case .unknown:
            return .keep(OrphanKeptRow(
                name: name, path: url.path,
                reason: "Could not verify the agent owner; kept"
            ))
        case .notInstalled:
            break
        }
        // Program / ProgramArguments are only evidence when absolute
        // (AGENTS.md); a relative program can resolve anywhere, so it
        // proves nothing.
        guard let programPath = Self.absoluteProgramPath(in: plist) else {
            return .keep(OrphanKeptRow(
                name: name, path: url.path,
                reason: "No absolute program path to verify; relative programs are never evidence"
            ))
        }
        if FileManager.default.fileExists(atPath: programPath) {
            return .keep(OrphanKeptRow(
                name: name, path: url.path,
                reason: "Agent program still installed: \(programPath)"
            ))
        }
        if Self.isProtectedHelperPath(programPath) {
            return .keep(OrphanKeptRow(
                name: name, path: url.path,
                reason: "Program path is a protected system helper location"
            ))
        }
        if let lastModified, now.timeIntervalSince(lastModified) < configuration.minimumOrphanAge {
            return .keep(OrphanKeptRow(
                name: name, path: url.path,
                reason: "Agent modified within the retention window"
            ))
        }
        return .orphan(
            reason: "Agent program no longer exists: \(programPath)",
            lastModified: lastModified
        )
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

    /// Absolute Program / first ProgramArguments path, or nil when absent
    /// or non-absolute (AGENTS.md absolute-only rule).
    static func absoluteProgramPath(in plist: [String: Any]) -> String? {
        if let program = plist["Program"] as? String {
            return program.hasPrefix("/") ? program : nil
        }
        if let args = plist["ProgramArguments"] as? [String], let first = args.first {
            return first.hasPrefix("/") ? first : nil
        }
        return nil
    }

    /// Helper locations that stay out of orphan verdicts even when their
    /// file is missing (AGENTS.md: PrivilegedHelperTools helpers are a
    /// protected family; an updater can temporarily hide the leaf).
    static func isProtectedHelperPath(_ path: String) -> Bool {
        let prefixes = [
            "/Library/PrivilegedHelperTools/", "/System/", "/usr/", "/Library/Apple/",
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }

    // MARK: Filesystem helpers

    struct ChildEntry {
        let name: String
        let url: URL
        let isDirectory: Bool
        let sizeBytes: Int64
        let modified: Date?
    }

    /// Direct children of a root, or nil when the root is unreadable or
    /// missing. Symlinks are skipped outright: resolving them could escape
    /// the scanned root, and a linked target is not a leftover.
    static func directChildren(of root: String) -> [ChildEntry]? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return nil }
        return children.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { return nil }
            return ChildEntry(
                name: child.lastPathComponent,
                url: child,
                isDirectory: values.isDirectory ?? false,
                sizeBytes: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate
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
