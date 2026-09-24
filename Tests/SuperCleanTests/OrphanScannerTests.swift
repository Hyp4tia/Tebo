import Foundation
import Testing
@testable import SuperClean

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

        func config(minimumOrphanAge: TimeInterval = 0) -> OrphanScanConfiguration {
            func joined(_ relative: String) -> String {
                library.appendingPathComponent(relative).path
            }
            return OrphanScanConfiguration(
                applicationSupportRoots: [joined("Application Support")],
                cacheRoots: [joined("Caches")],
                preferenceRoots: [joined("Preferences")],
                launchAgentRoots: [joined("LaunchAgents")],
                applicationRoots: [apps.path],
                minimumOrphanAge: minimumOrphanAge
            )
        }

        func scanner(
            minimumOrphanAge: TimeInterval = 0,
            lookup: (any BundleLookup)? = nil
        ) -> OrphanScanner {
            OrphanScanner(
                configuration: config(minimumOrphanAge: minimumOrphanAge),
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

    @Test("Flags bundle-id leftovers when no app owns them")
    func flagsBundleIDLeftovers() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installApp(folder: "Installed.app", bundleID: "com.installed.app")

        _ = try fixture.write("123456", at: "Application Support/com.gone.app/cache.db")
        _ = try fixture.write("data", at: "Caches/com.gone.app/a.txt")
        _ = try fixture.write("x", at: "Preferences/com.gone.app.plist")
        let agentURL = try fixture.writePlist(
            ["Label": "com.gone.agent", "ProgramArguments": [fixture.root.appendingPathComponent("uninstalled/Gone.app/Contents/MacOS/Gone").path]],
            at: "LaunchAgents/com.gone.agent.plist"
        )
        let agentSize = Int64((try? agentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        let report = await fixture.scanner().scan()

        #expect(report.itemCount == 4)
        let byCategory = Dictionary(grouping: report.orphans, by: \.category)
        #expect(byCategory[.applicationSupport]?.count == 1)
        #expect(byCategory[.caches]?.count == 1)
        #expect(byCategory[.preferences]?.count == 1)
        #expect(byCategory[.launchAgent]?.count == 1)

        let appSupport = try #require(byCategory[.applicationSupport]?.first)
        #expect(appSupport.name == "com.gone.app")
        #expect(appSupport.sizeBytes == 6)
        #expect(appSupport.lastModified != nil)
        #expect(appSupport.reason.contains("com.gone.app"))

        let agent = try #require(byCategory[.launchAgent]?.first)
        #expect(agent.reason.contains("/uninstalled/Gone.app"))
        #expect(report.totalBytes == 6 + 4 + 1 + agentSize)
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
        // org.openssh.ssh is a reverse-DNS name, but the sensitive gate
        // fires before any bundle probe (Mole apps.sh:410-420 order).
        _ = try fixture.write("data", at: "Application Support/org.openssh.ssh/x")
        _ = try fixture.write("data", at: "Application Support/1Password/x")
        _ = try fixture.write("data", at: "Caches/com.bitwarden.desktop/x")

        let report = await fixture.scanner().scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains { $0.name == "org.openssh.ssh" && $0.reason.contains("Security-sensitive") })
        #expect(report.kept.contains { $0.name == "1Password" })
        #expect(report.kept.contains { $0.name == "com.bitwarden.desktop" })
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

        let report = await fixture.scanner().scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains { $0.name == "Installed" && $0.reason == "Owned by installed app Installed" })
        #expect(report.kept.contains { $0.name == "com.installed.app" && $0.reason.contains("Owned by an installed app") })
        #expect(report.kept.contains { $0.name == "com.installed.app.plist" && $0.reason.contains("Agent belongs to installed app") })
    }

    @Test("Age gate keeps recent entries, flags stale ones")
    func ageGate() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("data", at: "Application Support/com.recent.app/x")

        // Fresh fixture: mtime is now, so a 1-hour retention window keeps it.
        let recentReport = await fixture.scanner(minimumOrphanAge: 3600).scan()
        #expect(recentReport.orphans.isEmpty)
        #expect(recentReport.kept.contains { $0.reason.contains("retention window") })

        // Same tree with the gate disabled: the missing bundle id decides.
        let agedReport = await fixture.scanner(minimumOrphanAge: 0).scan()
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

        #expect(report.orphans.isEmpty)
        #expect(report.kept.filter { $0.reason.contains("No bundle identifier") }.count == 4)
    }

    @Test("Keeps entries when the bundle lookup answers unknown")
    func keepsOnUnknownLookup() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("data", at: "Application Support/com.gone.app/x")

        let report = await fixture.scanner(lookup: UnknownLookup()).scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains { $0.reason.contains("unavailable") })
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
        #expect(report.kept.contains { $0.reason.contains("still installed") && $0.reason.contains("Helper") })
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
        #expect(report.kept.contains { $0.reason.contains("No absolute program path") })
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
        #expect(report.kept.contains { $0.name == "broken.plist" && $0.reason.contains("unreadable") })
        #expect(report.kept.contains { $0.name == "myagent.plist" && $0.reason.contains("not a bundle identifier") })
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

        let report = await fixture.scanner().scan()

        #expect(report.orphans.isEmpty)
        #expect(report.kept.contains { $0.name == "MaestroStudio" && $0.reason.contains("Owned by installed app Maestro Studio") })
        #expect(report.kept.contains { $0.name == "maestro-studio" })
    }

    @Test("Skips symlinks and dot-prefixed children")
    func skipsSymlinksAndDotDirs() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let target = try fixture.write("data", at: "Application Support/com.real.app/x")
        let caches = fixture.library.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: caches.appendingPathComponent("com.linked.app"),
            withDestinationURL: target.deletingLastPathComponent()
        )
        _ = try fixture.write("data", at: "Application Support/.config/x")

        let report = await fixture.scanner().scan()

        // The symlink and the dot directory are never evaluated at all,
        // and the real orphan the symlink points at still shows.
        #expect(report.orphans.count == 1)
        #expect(!report.kept.contains { $0.name == "com.linked.app" })
        #expect(!report.kept.contains { $0.name == ".config" })
        #expect(report.orphans.contains { $0.name == "com.real.app" })
    }

    @Test("Skips zero-size leftovers like Mole's size gate")
    func skipsZeroSize() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.write("", at: "Application Support/com.empty.app/.keep")

        let report = await fixture.scanner().scan()

        #expect(report.orphans.isEmpty)
        #expect(!report.kept.contains { $0.name == "com.empty.app" })
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
        // An orphaned directory with more entries than the budget allows.
        _ = try fixture.write("payload", at: "Application Support/com.gone.app/a.txt")
        _ = try fixture.write("payload", at: "Application Support/com.gone.app/b.txt")
        _ = try fixture.write("payload", at: "Application Support/com.gone.app/c.txt")
        _ = try fixture.write("payload", at: "Application Support/com.gone.app/d.txt")
        _ = try fixture.write("payload", at: "Application Support/com.gone.app/e.txt")

        var config = fixture.config()
        config.sizeWalkEntryBudget = 3
        let scanner = OrphanScanner(
            configuration: config,
            bundleLookup: InstalledAppsBundleLookup(
                appRoots: [fixture.apps.path], useSpotlightFallback: false
            )
        )

        let report = await scanner.scan()

        // The scan returned (a runaway walk would time this test out) and
        // the row is present with its size flagged incomplete so the UI
        // can show "unavailable" instead of a wrong exact number.
        let row = report.orphans.first { $0.name == "com.gone.app" }
        #expect(row != nil)
        #expect(row?.isSizeComplete == false)
        #expect(row?.displaySize == "Unavailable")
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
