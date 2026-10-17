import Foundation
import Testing
@testable import Tebo

// MARK: - OrphanScanner tests
// All scans run against fixture trees under a temp directory. The real
// ~/Library and /Applications are never touched: every root comes from an
// OrphanScanConfiguration pointing at the fixture, and the bundle lookup
// runs with the Spotlight fallback disabled.

@Suite("OrphanScanner")
struct OrphanScannerTests {

    /// Temp fixture tree:
    /// <root>/Library/{Application Support,Caches,Preferences,LaunchAgents}
    /// plus <root>/Applications for installed-app evidence.
    struct Fixture {
        let root: URL
        let library: URL
        let apps: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrphanScannerTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.root = root
            self.library = root.appendingPathComponent("Library", isDirectory: true)
            self.apps = root.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }

        /// Write text relative to the fixture Library, creating parents.
        @discardableResult
        func write(_ text: String, at relative: String) throws -> URL {
            let url = library.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
            return url
        }

        /// Write a plist (XML) relative to the fixture Library.
        func writePlist(_ plist: [String: Any], at relative: String) throws -> URL {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let url = library.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
            return url
        }

        /// A minimal installed .app bundle for ownership evidence.
        func installApp(
            folder: String,
            bundleID: String,
            bundleName: String? = nil,
            displayName: String? = nil
        ) throws {
            let contents = apps.appendingPathComponent(folder)
                .appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist: [String: Any] = ["CFBundleIdentifier": bundleID]
            if let bundleName { plist["CFBundleName"] = bundleName }
            if let displayName { plist["CFBundleDisplayName"] = displayName }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }

        func config(
            minimumOrphanAge: TimeInterval = 0,
            rebuildableCacheBundleIDs: Set<String> = []
        ) -> OrphanScanConfiguration {
            func joined(_ relative: String) -> String {
                library.appendingPathComponent(relative).path
            }
            return OrphanScanConfiguration(
                applicationSupportRoots: [joined("Application Support")],
                cacheRoots: [joined("Caches")],
                preferenceRoots: [joined("Preferences")],
                launchAgentRoots: [joined("LaunchAgents")],
                applicationRoots: [apps.path],
                minimumOrphanAge: minimumOrphanAge,
                rebuildableCacheBundleIDs: rebuildableCacheBundleIDs
            )
        }

        func scanner(
            minimumOrphanAge: TimeInterval = 0,
            rebuildableCacheBundleIDs: Set<String> = [],
            lookup: (any BundleLookup)? = nil
        ) -> OrphanScanner {
            OrphanScanner(
                configuration: config(
                    minimumOrphanAge: minimumOrphanAge,
                    rebuildableCacheBundleIDs: rebuildableCacheBundleIDs
                ),
                bundleLookup: lookup ?? InstalledAppsBundleLookup(
                    appRoots: [apps.path], useSpotlightFallback: false
                )
            )
        }
    }

    /// Stub that always answers unknown, pinning the fail-closed path.
    struct UnknownLookup: BundleLookup {
        func isInstalled(bundleID: String) async -> BundleLookupResult { .unknown }
    }

    struct NegativeOnlyLookup: BundleLookup {
        func isInstalled(bundleID: String) async -> BundleLookupResult { .notInstalled }
    }

    @Test("A lookup without a fresh probe cannot reuse negative absence at removal time")
    func freshLookupFallbackFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let cacheFile = try fixture.write("cache", at: "Caches/com.fixture.cache/cache.bin")
        let scanner = OrphanScanner(
            configuration: fixture.config(minimumOrphanAge: 0, rebuildableCacheBundleIDs: ["com.fixture.cache"]),
            bundleLookup: NegativeOnlyLookup()
        )

        let reason = await scanner.removalProtectionReason(
            for: cacheFile.deletingLastPathComponent().path, whitelist: []
        )

        #expect(reason?.contains("Fresh bundle lookup unavailable") == true)
    }

    @Test("Application Support, Preferences, and LaunchAgents are read-only even without an installed app")
    func personalStateIsReadOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("database", at: "Application Support/com.gone.app/history.sqlite")
        _ = try fixture.write("preferences", at: "Preferences/com.gone.app.plist")
        _ = try fixture.writePlist(
            ["Label": "com.gone.agent", "ProgramArguments": [fixture.root.appendingPathComponent("missing/agent").path]],
            at: "LaunchAgents/com.gone.agent.plist"
        )

        let report = await fixture.scanner(minimumOrphanAge: 0).scan()
        let paths = Set(report.kept.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })

        #expect(report.orphans.isEmpty)
        #expect(paths.contains(fixture.library.appendingPathComponent("Application Support/com.gone.app").resolvingSymlinksInPath().path))
        #expect(paths.contains(fixture.library.appendingPathComponent("Preferences/com.gone.app.plist").resolvingSymlinksInPath().path))
        #expect(paths.contains(fixture.library.appendingPathComponent("LaunchAgents/com.gone.agent.plist").resolvingSymlinksInPath().path))
    }

    @Test("Missing app ownership alone does not make a cache disposable")
    func cacheRequiresSupportedOwnerPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("cache", at: "Caches/com.gone.app/cache.bin")

        let report = await fixture.scanner(minimumOrphanAge: 0).scan()
        let kept = report.kept.first { $0.name == "com.gone.app" }
        let expected = fixture.library.appendingPathComponent("Caches/com.gone.app").resolvingSymlinksInPath().path

        #expect(report.orphans.isEmpty)
        #expect(kept.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path } == expected)
        #expect(kept?.reason.contains("supported cache-owner policy") == true)
    }

    @Test("A symlinked cache scan root is kept without traversal")
    func symlinkedCacheRootIsNotScanned() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("cache", at: "Caches/com.fixture.cache/cache.bin")
        let cacheRoot = fixture.library.appendingPathComponent("Caches", isDirectory: true)
        let alias = fixture.library.appendingPathComponent("CachesAlias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: cacheRoot)
        var config = fixture.config(rebuildableCacheBundleIDs: ["com.fixture.cache"])
        config.cacheRoots = [alias.path]
        let scanner = OrphanScanner(
            configuration: config,
            bundleLookup: InstalledAppsBundleLookup(appRoots: [fixture.apps.path], useSpotlightFallback: false)
        )

        let report = await scanner.scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains { $0.reason.contains("root is linked") })
    }

    @Test("A cache owner file is kept because only complete cache trees qualify")
    func cacheOwnerFileIsKept() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("not a tree", at: "Caches/com.fixture.cache")
        let scanner = fixture.scanner(
            rebuildableCacheBundleIDs: ["com.fixture.cache"]
        )

        let report = await scanner.scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains {
            $0.path.hasSuffix("/Caches/com.fixture.cache")
                && $0.reason.contains("not a directory")
        })
    }

    @Test("A recent descendant keeps an old-supported cache tree")
    func recentDescendantKeepsCache() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let old = Date(timeIntervalSinceNow: -60 * 24 * 60 * 60)
        let oldFile = try fixture.write("old", at: "Caches/com.fixture.cache/old.bin")
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: oldFile.path)
        let recentFile = try fixture.write("recent", at: "Caches/com.fixture.cache/nested/recent.bin")
        let cacheRoot = recentFile.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: cacheRoot.path)
        var config = fixture.config(minimumOrphanAge: 30 * 24 * 60 * 60)
        config.rebuildableCacheBundleIDs = ["com.fixture.cache"]
        let scanner = OrphanScanner(configuration: config, bundleLookup: InstalledAppsBundleLookup(
            appRoots: [fixture.apps.path], useSpotlightFallback: false
        ))

        let report = await scanner.scan()

        #expect(!report.orphans.contains {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                == cacheRoot.resolvingSymlinksInPath().path
        })
        #expect(report.kept.contains {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                == cacheRoot.resolvingSymlinksInPath().path
                && $0.reason.contains("retention window")
        })
    }

    @Test("An incomplete installed-app inventory keeps an otherwise supported cache")
    func incompleteAppInventoryKeepsCache() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let cache = try fixture.write("cache", at: "Caches/com.fixture.cache/cache.bin")
        let appContents = fixture.apps.appendingPathComponent("Unreadable.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: appContents, withIntermediateDirectories: true)
        try Data("not a property list".utf8).write(to: appContents.appendingPathComponent("Info.plist"))
        var config = fixture.config(minimumOrphanAge: 0)
        config.rebuildableCacheBundleIDs = ["com.fixture.cache"]
        let scanner = OrphanScanner(configuration: config, bundleLookup: InstalledAppsBundleLookup(
            appRoots: [fixture.apps.path], useSpotlightFallback: false
        ))

        let report = await scanner.scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: cache.deletingLastPathComponent().path).resolvingSymlinksInPath().path
                && $0.reason.contains("inventory is incomplete")
        })
    }

    @Test("Removal policy refreshes a cached negative bundle lookup")
    func removalLookupIsFresh() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let cacheFile = try fixture.write("cache", at: "Caches/com.fixture.cache/cache.bin")
        var config = fixture.config(minimumOrphanAge: 0)
        config.rebuildableCacheBundleIDs = ["com.fixture.cache"]
        let lookup = InstalledAppsBundleLookup(appRoots: [fixture.apps.path], useSpotlightFallback: false)
        let scanner = OrphanScanner(configuration: config, bundleLookup: lookup)

        let firstPass = await scanner.scan()
        #expect(firstPass.orphans.contains {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                == cacheFile.deletingLastPathComponent().resolvingSymlinksInPath().path
        })
        try fixture.installApp(folder: "NewlyInstalled.app", bundleID: "com.fixture.cache")
        let reason = await scanner.removalProtectionReason(
            for: cacheFile.deletingLastPathComponent().path, whitelist: []
        )

        #expect(reason?.contains("Owned by an installed app") == true)
    }

    @Test("Final cache validation refuses a symlinked ancestor alias")
    func finalCacheValidationRejectsSymlinkAncestor() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("cache", at: "Caches/com.fixture.cache/cache.bin")
        let config = fixture.config(minimumOrphanAge: 0, rebuildableCacheBundleIDs: ["com.fixture.cache"])
        let cacheRoot = fixture.library.appendingPathComponent("Caches", isDirectory: true)
        let alias = fixture.library.appendingPathComponent("CachesAlias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: cacheRoot)
        let scanner = OrphanScanner(
            configuration: config,
            bundleLookup: InstalledAppsBundleLookup(appRoots: [fixture.apps.path], useSpotlightFallback: false)
        )

        let reason = await scanner.removalProtectionReason(
            for: alias.appendingPathComponent("com.fixture.cache").path, whitelist: []
        )

        #expect(reason?.contains("direct child") == true)
    }

    @Test("Spotlight truncation cannot establish that an app is absent")
    func spotlightTruncationIsUnknown() {
        #expect(InstalledAppsBundleLookup.spotlightResult(
            terminationStatus: 0, stdout: "", outputTruncated: true
        ) == .unknown)
        #expect(InstalledAppsBundleLookup.spotlightResult(
            terminationStatus: 0, stdout: "", outputTruncated: false
        ) == .notInstalled)
    }

    @Test("An explicitly supported stale cache owner is still discoverable")
    func supportedCachePositiveControl() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let cacheFile = try fixture.write("rebuildable", at: "Caches/com.fixture.cache/cache.bin")
        let old = Date(timeIntervalSinceNow: -45 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: cacheFile.path)
        let cacheRoot = cacheFile.deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: cacheRoot.path)

        var config = fixture.config(minimumOrphanAge: 30 * 24 * 60 * 60)
        config.rebuildableCacheBundleIDs = ["com.fixture.cache"]
        let scanner = OrphanScanner(configuration: config, bundleLookup: InstalledAppsBundleLookup(
            appRoots: [fixture.apps.path], useSpotlightFallback: false
        ))
        let report = await scanner.scan()

        #expect(report.orphans.count == 1)
        #expect(report.orphans.first.map {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
        } == cacheRoot.resolvingSymlinksInPath().path)
        #expect(report.orphans.first?.category == .caches)
        #expect(report.orphans.first?.sizeBytes == Int64("rebuildable".utf8.count))
    }

    @Test("Flags bundle-id leftovers when no app owns them")
    func flagsBundleIDLeftovers() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installApp(folder: "Installed.app", bundleID: "com.installed.app")

        _ = try fixture.write("123456", at: "Application Support/com.gone.app/cache.db")
        _ = try fixture.write("data", at: "Caches/com.gone.app/a.txt")
        _ = try fixture.write("x", at: "Preferences/com.gone.app.plist")
        _ = try fixture.writePlist(
            ["Label": "com.gone.agent", "ProgramArguments": [fixture.root.appendingPathComponent("uninstalled/Gone.app/Contents/MacOS/Gone").path]],
            at: "LaunchAgents/com.gone.agent.plist"
        )
        let report = await fixture.scanner(
            rebuildableCacheBundleIDs: ["com.gone.app"]
        ).scan()

        #expect(report.itemCount == 1)
        #expect(report.orphans.first?.category == .caches)
        #expect(report.orphans.first?.path.hasSuffix("/Caches/com.gone.app") == true)
        #expect(report.totalBytes == 4)
        let keptPaths = Set(report.kept.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
        #expect(keptPaths.contains(fixture.library.appendingPathComponent("Application Support/com.gone.app").resolvingSymlinksInPath().path))
        #expect(keptPaths.contains(fixture.library.appendingPathComponent("Preferences/com.gone.app.plist").resolvingSymlinksInPath().path))
        #expect(keptPaths.contains(fixture.library.appendingPathComponent("LaunchAgents/com.gone.agent.plist").resolvingSymlinksInPath().path))
    }

    @Test("Keeps Apple system names")
    func keepsAppleSystemNames() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("data", at: "Application Support/com.apple.finder/x")
        _ = try fixture.write("data", at: "Caches/com.apple.WebKit/x")
        _ = try fixture.write("x", at: "Preferences/loginwindow.plist")
        _ = try fixture.write("x", at: "Preferences/com.apple.spaces.plist")

        let report = await fixture.scanner().scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains { $0.reason.contains("Apple system component") })
        #expect(report.kept.contains { $0.name == "loginwindow.plist" })
        #expect(report.kept.contains { $0.name == "com.apple.spaces.plist" })
    }

    @Test("Keeps security-sensitive names even as bundle ids")
    func keepsSensitiveNames() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // These reverse-DNS cache owners are explicitly opted in only to prove
        // the security-sensitive owner gate wins before absence is considered.
        _ = try fixture.write("data", at: "Caches/org.openssh.ssh/x")
        _ = try fixture.write("data", at: "Caches/com.1password.manager/x")
        _ = try fixture.write("data", at: "Caches/com.bitwarden.desktop/x")

        let report = await fixture.scanner(
            rebuildableCacheBundleIDs: ["org.openssh.ssh", "com.1password.manager", "com.bitwarden.desktop"]
        ).scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.filter { $0.reason.contains("Security-sensitive") }.count == 3)
        #expect(Set(report.kept.map(\.name)).isSuperset(of: [
            "org.openssh.ssh", "com.1password.manager", "com.bitwarden.desktop",
        ]))
    }

    @Test("Keeps entries owned by an installed app")
    func keepsOwnedByInstalledApp() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installApp(folder: "Installed.app", bundleID: "com.installed.app", bundleName: "Installed")

        _ = try fixture.write("data", at: "Application Support/Installed/x")
        _ = try fixture.write("data", at: "Caches/com.installed.app/x")
        _ = try fixture.write("x", at: "Preferences/com.installed.app.plist")
        _ = try fixture.writePlist(["Label": "com.installed.app", "ProgramArguments": ["/bin/true"]], at: "LaunchAgents/com.installed.app.plist")

        let report = await fixture.scanner(
            rebuildableCacheBundleIDs: ["com.installed.app"]
        ).scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains { $0.name == "Installed" && $0.reason.contains("personal app data") })
        #expect(report.kept.contains { $0.name == "com.installed.app" && $0.reason.contains("Owned by an installed app") })
        #expect(report.kept.contains { $0.name == "com.installed.app.plist" && $0.reason.contains("LaunchAgents") })
    }

    @Test("Age gate keeps recent entries, flags stale ones")
    func ageGate() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("data", at: "Caches/com.recent.app/x")

        // Fresh fixture: a one-hour retention window keeps the whole cache tree.
        let recentReport = await fixture.scanner(
            minimumOrphanAge: 3600, rebuildableCacheBundleIDs: ["com.recent.app"]
        ).scan()
        #expect(recentReport.orphans.isEmpty)
        #expect(recentReport.kept.contains { $0.reason.contains("retention window") })

        // Same tree with the age gate disabled and explicit cache policy.
        let agedReport = await fixture.scanner(
            minimumOrphanAge: 0, rebuildableCacheBundleIDs: ["com.recent.app"]
        ).scan()
        #expect(agedReport.itemCount == 1)
        #expect(agedReport.orphans.first?.name == "com.recent.app")
    }

    @Test("Keeps non-bundle-id names as possible CLI or system data")
    func keepsNonBundleIDNames() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("data", at: "Application Support/SomeCLITool/x")
        _ = try fixture.write("data", at: "Application Support/Maestro Studio/x")
        _ = try fixture.write("data", at: "Caches/nginx/x")
        _ = try fixture.write("x", at: "Preferences/foo.plist")

        let report = await fixture.scanner().scan()
        let keptPaths = Set(report.kept.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })

        #expect(report.orphans.isEmpty)
        #expect(keptPaths.contains(fixture.library.appendingPathComponent("Application Support/SomeCLITool").resolvingSymlinksInPath().path))
        #expect(keptPaths.contains(fixture.library.appendingPathComponent("Application Support/Maestro Studio").resolvingSymlinksInPath().path))
        #expect(keptPaths.contains(fixture.library.appendingPathComponent("Caches/nginx").resolvingSymlinksInPath().path))
        #expect(keptPaths.contains(fixture.library.appendingPathComponent("Preferences/foo.plist").resolvingSymlinksInPath().path))
    }

    @Test("Keeps entries when the bundle lookup answers unknown")
    func keepsOnUnknownLookup() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("data", at: "Caches/com.gone.app/x")

        let report = await fixture.scanner(
            rebuildableCacheBundleIDs: ["com.gone.app"], lookup: UnknownLookup()
        ).scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains { $0.reason.contains("Bundle lookup unavailable") })
    }

    @Test("Keeps LaunchAgents whose program still exists")
    func keepsAgentWithExistingProgram() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // Helper lives outside the Library roots so it is scanned only as
        // an agent target, never as a leftover candidate itself.
        let helper = fixture.root.appendingPathComponent("Bin/Helper")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        _ = try fixture.writePlist(
            ["Label": "com.gone.agent", "ProgramArguments": [helper.path, "--flag"]],
            at: "LaunchAgents/com.gone.agent.plist"
        )

        let report = await fixture.scanner().scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains {
            $0.path.hasSuffix("LaunchAgents/com.gone.agent.plist")
                && $0.reason == "LaunchAgents are user-owned automation and remain read-only"
        })
    }

    @Test("Keeps agents with no absolute program path")
    func keepsAgentWithRelativeProgram() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.writePlist(
            ["Label": "com.gone.agent", "Program": "open"],
            at: "LaunchAgents/com.gone.agent.plist"
        )

        let report = await fixture.scanner().scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains {
            $0.path.hasSuffix("LaunchAgents/com.gone.agent.plist")
                && $0.reason == "LaunchAgents are user-owned automation and remain read-only"
        })
    }

    @Test("Keeps unreadable agent plists and non-bundle-id labels")
    func keepsUnverifiableAgents() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("not a plist", at: "LaunchAgents/broken.plist")
        _ = try fixture.writePlist(
            ["Label": "myagent", "ProgramArguments": [fixture.root.appendingPathComponent("gone/tool").path]],
            at: "LaunchAgents/myagent.plist"
        )

        let report = await fixture.scanner().scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains {
            $0.name == "broken.plist" && $0.path.hasSuffix("LaunchAgents/broken.plist")
                && $0.reason == "LaunchAgents are user-owned automation and remain read-only"
        })
        #expect(report.kept.contains {
            $0.name == "myagent.plist" && $0.path.hasSuffix("LaunchAgents/myagent.plist")
                && $0.reason == "LaunchAgents are user-owned automation and remain read-only"
        })
    }

    @Test("Matches Mole naming variants for installed apps")
    func matchesMoleNamingVariants() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installApp(
            folder: "Maestro Studio.app",
            bundleID: "com.maestro.studio",
            bundleName: "Maestro Studio",
            displayName: "Maestro Studio"
        )
        _ = try fixture.write("data", at: "Application Support/MaestroStudio/x")
        _ = try fixture.write("data", at: "Application Support/maestro-studio/x")
        _ = try fixture.write("data", at: "Caches/com.maestro.studio/cache.bin")

        let report = await fixture.scanner(
            rebuildableCacheBundleIDs: ["com.maestro.studio"]
        ).scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains { $0.name == "MaestroStudio" && $0.reason.contains("personal app data") })
        #expect(report.kept.contains { $0.name == "maestro-studio" && $0.reason.contains("personal app data") })
        #expect(report.kept.contains {
            $0.path.hasSuffix("Caches/com.maestro.studio")
                && $0.reason.contains("Owned by an installed app")
        })
    }

    @Test("Symlink cache entries are kept without following either link")
    func skipsSymlinksAndDotDirs() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("data"))
        _ = try fixture.write("rebuildable", at: "Caches/com.real.app/cache.bin")
        let cacheRoot = fixture.library.appendingPathComponent("Caches/com.real.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: cacheRoot.appendingPathComponent("linked"), withDestinationURL: outside
        )
        let caches = fixture.library.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: caches.appendingPathComponent("com.linked.app"), withDestinationURL: outside
        )
        _ = try fixture.write("dot state", at: "Caches/.config/x")

        let report = await fixture.scanner(
            rebuildableCacheBundleIDs: ["com.real.app"]
        ).scan()
        let unsafeSuffix = "/\(fixture.root.lastPathComponent)/Library/Caches/com.real.app"

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains {
            $0.path.hasSuffix(unsafeSuffix) && $0.reason.contains("symlink")
        })
        #expect(report.kept.contains {
            $0.path.hasSuffix("/\(fixture.root.lastPathComponent)/Library/Caches/.config")
                && $0.reason.contains("Dot-prefixed")
        })
        #expect(report.kept.contains {
            $0.name == "com.linked.app"
                && $0.path.hasSuffix("/Library/Caches/com.linked.app")
                && $0.reason.lowercased().contains("symlink")
        })
        #expect(!report.orphans.contains { $0.path.hasSuffix(unsafeSuffix) })
    }

    @Test("Skips zero-size leftovers like Mole's size gate")
    func skipsZeroSize() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("", at: "Caches/com.empty.app/.keep")

        let report = await fixture.scanner(
            rebuildableCacheBundleIDs: ["com.empty.app"]
        ).scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains {
            $0.path.hasSuffix("Caches/com.empty.app")
                && $0.reason.contains("positive-size evidence")
        })
    }

    @Test("Never scans Preferences/ByHost")
    func skipsByHostPreferences() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("x", at: "Preferences/ByHost/com.gone.app.plist")

        let report = await fixture.scanner().scan()

        #expect(report.orphans.isEmpty)
        #expect(!report.kept.contains { $0.path.contains("ByHost") })
    }

    @Test("Size walk past its entry budget reports incomplete size, never hangs")
    func sizeWalkBudgetStopsTheWalk() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // A supported cache tree with more entries than the evidence budget
        // must be kept, not exposed with a partial size or age verdict.
        _ = try fixture.write("payload", at: "Caches/com.gone.app/a.txt")
        _ = try fixture.write("payload", at: "Caches/com.gone.app/b.txt")
        _ = try fixture.write("payload", at: "Caches/com.gone.app/c.txt")
        _ = try fixture.write("payload", at: "Caches/com.gone.app/d.txt")
        _ = try fixture.write("payload", at: "Caches/com.gone.app/e.txt")

        var config = fixture.config(rebuildableCacheBundleIDs: ["com.gone.app"])
        config.sizeWalkEntryBudget = 3
        let scanner = OrphanScanner(
            configuration: config,
            bundleLookup: InstalledAppsBundleLookup(
                appRoots: [fixture.apps.path], useSpotlightFallback: false
            )
        )

        let report = await scanner.scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains {
            $0.path.hasSuffix("Caches/com.gone.app")
                && $0.reason.contains("traversal is incomplete")
        })
    }

    @Test("Name variants cover Mole's forms")
    func nameVariantsCoverMoleForms() {
        let variants = InstalledAppIndex.nameVariants(of: "Zed Nightly")
        #expect(variants.contains("zed nightly"))
        #expect(variants.contains("zednightly"))
        #expect(variants.contains("zed_nightly"))
        #expect(variants.contains("zed-nightly"))
        #expect(variants.contains("zed"))

        let developer = InstalledAppIndex.nameVariants(of: "Firefox Developer Edition")
        #expect(developer.contains("firefox"))
    }
}
