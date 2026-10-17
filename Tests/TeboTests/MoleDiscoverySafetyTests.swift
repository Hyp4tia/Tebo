import Foundation
import Testing
@testable import Tebo

@Suite("Mole discovery safety")
struct MoleDiscoverySafetyTests {
    @Test("Only the cache leaf survives review-only overlap, never personal state")
    func mergeKeepsPersonalStateAndReviewOnlyProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoleDiscoverySafety-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let downloads = library.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)

        func write(_ contents: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }

        let cache = downloads.appendingPathComponent("com.fixture.cache", isDirectory: true)
        try write("cache payload", to: cache.appendingPathComponent("cache.bin"))
        let installerPath = cache.appendingPathComponent("setup.dmg")
        try write("dmg payload", to: installerPath)
        let old = Date(timeIntervalSinceNow: -120 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: installerPath.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: cache.path)

        let applicationSupport = library.appendingPathComponent("Application Support/com.gone.app", isDirectory: true)
        try write("database", to: applicationSupport.appendingPathComponent("history.sqlite"))
        let preference = library.appendingPathComponent("Preferences/com.gone.app.plist")
        try write("preference", to: preference)
        let launchAgent = library.appendingPathComponent("LaunchAgents/com.gone.agent.plist")
        try write("agent", to: launchAgent)

        let orphanScanner = OrphanScanner(
            configuration: OrphanScanConfiguration(
                applicationSupportRoots: [library.appendingPathComponent("Application Support").path],
                cacheRoots: [downloads.path],
                preferenceRoots: [library.appendingPathComponent("Preferences").path],
                launchAgentRoots: [library.appendingPathComponent("LaunchAgents").path],
                applicationRoots: [apps.path],
                minimumOrphanAge: 0,
                rebuildableCacheBundleIDs: ["com.fixture.cache"]
            ),
            bundleLookup: InstalledAppsBundleLookup(appRoots: [apps.path], useSpotlightFallback: false)
        )
        let orphanReport = await orphanScanner.scan(whitelist: [])
        let installerFinder = InstallerFinder(configuration: InstallerScanConfiguration(searchRoots: [downloads.path]))
        let installers = await installerFinder.findInstallers()
        let merged = CleanResultCombiner.merge(
            tableRows: [], orphans: orphanReport.orphans, installers: installers,
            now: Date(timeIntervalSinceNow: 30 * 86_400)
        )
        let protectedPaths = orphanReport.kept.map(\.path)
        let prefix = "/\(root.lastPathComponent)/Library"
        let cacheSuffix = prefix + "/Caches/com.fixture.cache"
        let installerSuffix = cacheSuffix + "/setup.dmg"

        #expect(orphanReport.orphans.count == 1)
        #expect(orphanReport.orphans.first?.path.hasSuffix(cacheSuffix) == true)
        #expect(protectedPaths.contains { $0.hasSuffix(prefix + "/Application Support/com.gone.app") })
        #expect(protectedPaths.contains { $0.hasSuffix(prefix + "/Preferences/com.gone.app.plist") })
        #expect(protectedPaths.contains { $0.hasSuffix(prefix + "/LaunchAgents/com.gone.agent.plist") })
        #expect(merged.count == 1)
        #expect(merged.first?.path.hasSuffix(installerSuffix) == true)
        #expect(merged.first?.cleanupSource == .installer)
        #expect(merged.first?.recommendedForSelection == false)
        #expect(merged.reduce(0) { $0 + $1.sizeBytes } == Int64("dmg payload".utf8.count))
    }
}
