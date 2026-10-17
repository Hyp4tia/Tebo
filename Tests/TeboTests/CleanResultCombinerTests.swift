import Foundation
import Testing
@testable import Tebo

@Suite("Combined Clean scan")
struct CleanResultCombinerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Installers in Clean preserve source and stay unselected")
    func installersInClean() {
        let files = [
            InstallerFile(path: "/tmp/old.dmg", sizeBytes: 100, lastModified: now.addingTimeInterval(-40 * 86_400), kind: .diskImage, source: "Downloads"),
            InstallerFile(path: "/tmp/recent.pkg", sizeBytes: 200, lastModified: now.addingTimeInterval(-2 * 86_400), kind: .package, source: "Desktop"),
            InstallerFile(path: "/tmp/unknown.iso", sizeBytes: 300, lastModified: nil, kind: .isoArchive, source: "Downloads")
        ]
        let rows = CleanResultCombiner.merge(tableRows: [], orphans: [], installers: files, now: now)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.category == "Downloaded Installers" })
        #expect(rows.allSatisfy { !$0.recommendedForSelection })
        #expect(rows.allSatisfy { $0.cleanupSource == .installer })
        #expect(rows.first?.reason == "DMG installer in Downloads")
    }

    @Test("Installers stay manual review regardless of age")
    func installersRemainManualReview() {
        let files = [
            InstallerFile(path: "/tmp/old.dmg", sizeBytes: 100,
                          lastModified: now.addingTimeInterval(-400 * 86_400),
                          kind: .diskImage, source: "Downloads"),
            InstallerFile(path: "/tmp/recent.pkg", sizeBytes: 200,
                          lastModified: now.addingTimeInterval(-2 * 86_400),
                          kind: .package, source: "Desktop"),
        ]
        let rows = CleanResultCombiner.merge(tableRows: [], orphans: [], installers: files, now: now)

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.recommendedForSelection })
        #expect(rows.allSatisfy { $0.cleanupSource == .installer })
    }

    @Test("The same path from multiple scans is counted and offered only once")
    func noDuplicateRemovalRows() {
        let original = ScanResult(
            path: "/tmp/same.dmg", sizeBytes: 100, category: "Cache", reason: "Existing rule",
            recommendedForSelection: true, cleanupSource: .moleRule("fixture-rule")
        )
        let installer = InstallerFile(path: original.path, sizeBytes: 100, lastModified: now, kind: .diskImage, source: "Downloads")
        let rows = CleanResultCombiner.merge(tableRows: [original, original], orphans: [], installers: [installer], now: now)
        #expect(rows.count == 1)
        #expect(rows.first?.cleanupSource == .installer)
        #expect(rows.first?.recommendedForSelection == false)
        #expect(rows.first?.reason.contains("Existing rule") == true)
        #expect(rows.reduce(0) { $0 + $1.sizeBytes } == 100)
    }

    @Test("Review-only installer evidence wins over an exact automatic match")
    func exactConflictKeepsManualReviewStatus() {
        let safe = ScanResult(
            path: "/tmp/downloads/package.dmg", sizeBytes: 2048,
            category: "Download cache", reason: "Automatic cache rule",
            recommendedForSelection: true, cleanupSource: .moleRule("downloads-cache")
        )
        let installer = InstallerFile(
            path: safe.path, sizeBytes: 2048, lastModified: now.addingTimeInterval(-500 * 86_400),
            kind: .diskImage, source: "Downloads"
        )

        let rows = CleanResultCombiner.merge(tableRows: [safe], orphans: [], installers: [installer], now: now)

        #expect(rows.count == 1)
        #expect(rows[0].path == safe.path)
        #expect(rows[0].cleanupSource == .installer)
        #expect(!rows[0].recommendedForSelection)
    }

    @Test("Pre-tagged review-only rows can never remain recommended")
    func reviewOnlyTagsCannotBeRecommended() {
        let installer = ScanResult(
            path: "/tmp/review.dmg", sizeBytes: 10, category: "Installer", reason: "Manual review",
            recommendedForSelection: true, cleanupSource: .installer
        )
        let orphan = ScanResult(
            path: "/tmp/cache", sizeBytes: 20, category: "Orphan cache", reason: "Review cache",
            recommendedForSelection: true, cleanupSource: .orphanCache("com.fixture.cache")
        )

        let rows = CleanResultCombiner.merge(tableRows: [installer, orphan], orphans: [], installers: [], now: now)

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.recommendedForSelection })
    }

    @Test("A reviewed installer descendant prevents automatic ancestor authorization")
    func installerDescendantSuppressesAncestor() {
        let cache = ScanResult(
            path: "/tmp/Homebrew", sizeBytes: 500, category: "Cache", reason: "Cache folder",
            recommendedForSelection: true, cleanupSource: .moleRule("homebrew-cache")
        )
        let installer = InstallerFile(
            path: "/tmp/Homebrew/downloads/setup.dmg", sizeBytes: 100,
            lastModified: now.addingTimeInterval(-500 * 86_400), kind: .diskImage, source: "Homebrew"
        )

        let rows = CleanResultCombiner.merge(tableRows: [cache], orphans: [], installers: [installer], now: now)

        #expect(rows.map(\.path) == [installer.path])
        #expect(rows.first?.cleanupSource == .installer)
        #expect(rows.first?.recommendedForSelection == false)
        #expect(rows.reduce(0) { $0 + $1.sizeBytes } == installer.sizeBytes)
    }

    @Test("Orphan cache rows retain their discovery provenance and review status")
    func orphanProvenanceIsPreserved() {
        let orphan = OrphanRow(
            name: "com.fixture.cache", path: "/tmp/Caches/com.fixture.cache", sizeBytes: 64,
            lastModified: now.addingTimeInterval(-90 * 86_400), category: .caches,
            reason: "Explicitly supported rebuildable cache"
        )

        let rows = CleanResultCombiner.merge(tableRows: [], orphans: [orphan], installers: [], now: now)

        #expect(rows.count == 1)
        #expect(rows[0].cleanupSource == .orphanCache("com.fixture.cache"))
        #expect(!rows[0].recommendedForSelection)
    }

    @Test("Incomplete orphan measurements retain their lower-bound marker")
    func partialOrphanSizes() {
        let orphan = OrphanRow(name: "app", path: "/tmp/app", sizeBytes: 25, isSizeComplete: false,
                               lastModified: nil, category: .caches, reason: "No owner")
        let rows = CleanResultCombiner.merge(tableRows: [], orphans: [orphan], installers: [], now: now)
        #expect(rows.first?.isSizeComplete == false)
        #expect(rows.first?.displaySize.hasPrefix("≥ ") == true)
    }

    @Test("Installers inside an existing cleanup folder are not counted twice")
    func containedInstallers() {
        let cache = ScanResult(path: "/tmp/Homebrew", sizeBytes: 500, category: "Cache", reason: "Cache folder")
        let included = InstallerFile(path: "/tmp/Homebrew/downloads/setup.dmg", sizeBytes: 100,
                                     lastModified: now, kind: .diskImage, source: "Homebrew")
        let separate = InstallerFile(path: "/tmp/Homebrew-other/setup.dmg", sizeBytes: 200,
                                     lastModified: now, kind: .diskImage, source: "Downloads")
        let rows = CleanResultCombiner.merge(tableRows: [cache], orphans: [], installers: [included, separate], now: now)
        #expect(rows.map(\.path) == [included.path, separate.path])
        #expect(rows.first?.cleanupSource == .installer)
        #expect(rows.first?.recommendedForSelection == false)
        #expect(rows.reduce(0) { $0 + $1.sizeBytes } == 300)
    }
}
