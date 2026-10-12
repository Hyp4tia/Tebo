import Foundation
import Testing
@testable import Tebo

@Suite("Combined Clean scan")
struct CleanResultCombinerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Installers appear in Clean with conservative age recommendations")
    func installersInClean() {
        let files = [
            InstallerFile(path: "/tmp/old.dmg", sizeBytes: 100, lastModified: now.addingTimeInterval(-40 * 86_400), kind: .diskImage, source: "Downloads"),
            InstallerFile(path: "/tmp/recent.pkg", sizeBytes: 200, lastModified: now.addingTimeInterval(-2 * 86_400), kind: .package, source: "Desktop"),
            InstallerFile(path: "/tmp/unknown.iso", sizeBytes: 300, lastModified: nil, kind: .isoArchive, source: "Downloads")
        ]
        let rows = CleanResultCombiner.merge(tableRows: [], orphans: [], installers: files, now: now)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.category == "Downloaded Installers" })
        #expect(rows.filter(\.recommendedForSelection).map(\.path) == ["/tmp/old.dmg"])
        #expect(rows.first?.reason == "DMG installer in Downloads")
    }

    @Test("The same path from multiple scans is counted and offered only once")
    func noDuplicateRemovalRows() {
        let original = ScanResult(path: "/tmp/same.dmg", sizeBytes: 100, category: "Cache", reason: "Existing rule")
        let installer = InstallerFile(path: original.path, sizeBytes: 100, lastModified: now, kind: .diskImage, source: "Downloads")
        let rows = CleanResultCombiner.merge(tableRows: [original, original], orphans: [], installers: [installer], now: now)
        #expect(rows == [original])
        #expect(rows.reduce(0) { $0 + $1.sizeBytes } == 100)
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
        #expect(rows.map(\.path) == [cache.path, separate.path])
        #expect(rows.reduce(0) { $0 + $1.sizeBytes } == 700)
    }
}
