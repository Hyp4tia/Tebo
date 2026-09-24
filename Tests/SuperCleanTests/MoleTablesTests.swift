import Foundation
import Testing
@testable import SuperClean

// MARK: - MoleTables tests
// The tables are DATA ported from tw93/Mole's bash (GPL-3.0). These tests pin
// the invariants a scanner depends on: complete rows, traceable sources,
// unique paths per table, nothing pipeline-deletable pointing at system
// territory, everything resolving to an absolute path, and a stable count per
// group so accidental table shrinkage fails the build.
// Run: swift test

private extension MoleTablesTests {
    // Literal (wildcard-free) resolved prefix of a path, used for containment
    // checks. Tables never start a path with a wildcard.
    func resolvedPrefix(_ target: CleanTarget, home: String) -> String {
        let full = MolePathResolver.resolve(target.path, home: home)
        var prefix = String(full.prefix(while: { $0 != "*" }))
        // Trim trailing slashes only — the leading slash is what makes the
        // absolute-path containment checks meaningful.
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return prefix
    }
}

@Suite("MoleTables")
struct MoleTablesTests {

    /// Every table, newest first, with the group it must belong to.
    private static let tables: [(name: String, rows: [CleanTarget], group: MoleGroup)] = [
        ("UserEssentials", UserEssentials.all, .userEssentials),
        ("AppCaches", AppCaches.all, .appCaches),
        ("Browsers", Browsers.all, .browsers),
        ("GuiApps", GuiApps.all, .guiApps),
        ("DeveloperTools", DeveloperTools.all, .developerTools),
        ("CloudOffice", CloudOffice.all, .cloudOffice),
        ("SystemPaths", SystemPaths.all, .systemPaths),
        ("Virtualization", Virtualization.all, .virtualization),
        ("Firmware", Firmware.all, .firmware),
        ("TimeMachine", TimeMachine.all, .timeMachine),
    ]

    // MARK: - Table shape

    @Test("Every table is non-empty")
    func tablesNonEmpty() {
        for (name, rows, _) in Self.tables {
            #expect(!rows.isEmpty, "\\(name) table is empty")
        }
    }

    @Test("Every row has label, group, explanation and source")
    func rowsComplete() {
        for (_, rows, group) in Self.tables {
            for row in rows {
                #expect(!row.label.isEmpty, "empty label in \\(group.rawValue)")
                #expect(row.group == group, "\\(row.label) in wrong group")
                #expect(!row.explanation.isEmpty, "no explanation for \\(row.label)")
                #expect(!row.source.isEmpty, "no source for \\(row.label)")
                #expect(row.source.hasPrefix("mole lib/"), "unexpected source format: \\(row.source)")
            }
        }
    }

    @Test("No duplicate paths within a table")
    func noDuplicatePaths() {
        for (name, rows, _) in Self.tables {
            // Admin-only rows are report-only by construction; several legitimately
            // share one find root (e.g. /private/var/folders) with different
            // predicates, and the pipeline never scans them anyway.
            let raws = rows.filter { !$0.needsAdmin }.map { row -> String in
                switch row.path {
                case .homeRelative(let relative): return "~/\(relative)"
                case .absolute(let absolute): return absolute
                }
            }
            #expect(Set(raws).count == raws.count, "duplicate path in \(name): \(raws)")
        }
    }

    // MARK: - Safety

    @Test("Pipeline-deletable rows never point at protected or critical system paths")
    func noProtectedSystemPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedPrefixes = [
            "/System", "/Library", "/usr/", "/bin/", "/sbin/", "/etc/",
            "/private/var", "/private/etc", "/Volumes",
        ]
        for row in MoleTables.allTargets {
            // Admin-only rows are report-only by construction and can point at
            // system territory for display; the pipeline never deletes them.
            if row.needsAdmin { continue }
            let prefix = resolvedPrefix(row, home: home)
            #expect(!prefix.isEmpty, "\\(row.label): empty resolved path")
            #expect(prefix != "/", "\\(row.label): points at filesystem root")
            #expect(prefix != home, "\\(row.label): points at the whole home directory")
            for protected in protectedPrefixes {
                #expect(
                    !prefix.hasPrefix(protected),
                    "\\(row.label): protected path \\(prefix) (source \\(row.source))"
                )
            }
        }
    }

    @Test("Home-relative rows resolve under the current user's home")
    func homeRelativeRowsResolveUnderHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for (_, rows, _) in Self.tables {
            for row in rows {
                guard case .homeRelative = row.path else { continue }
                let prefix = resolvedPrefix(row, home: home)
                #expect(
                    prefix.hasPrefix(home + "/"),
                    "\\(row.label): \\(prefix) not under home (source \\(row.source))"
                )
            }
        }
    }

    @Test("Every target resolves to an absolute path")
    func everyTargetResolvesToAbsolutePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for row in MoleTables.allTargets {
            let resolved = MolePathResolver.resolve(row.path, home: home)
            #expect(resolved.hasPrefix("/"), "\\(row.label): \\(resolved) is not absolute")
        }
    }

    @Test("No .safe target path points at a real user-data location")
    func noSafeTargetUnderUserData() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userDataDirs = ["Trash", "Desktop", "Documents", "Movies", "Pictures"]
        for row in MoleTables.allTargets where row.risk == .safe {
            let prefix = resolvedPrefix(row, home: home)
            for dir in userDataDirs {
                let dirPath = (home as NSString).appendingPathComponent(dir)
                #expect(
                    prefix != dirPath && !prefix.hasPrefix(dirPath + "/"),
                    "\\(row.label) (.safe) points at user data \\(dirPath) (source \\(row.source))"
                )
            }
        }
    }

    @Test("Rows needing admin are never pipeline-deletable")
    func needsAdminRowsAreReportOnly() {
        for row in MoleTables.allTargets where row.needsAdmin {
            #expect(row.reportOnly, "\\(row.label) needs admin but is not report-only")
        }
    }

    // MARK: - Counts (accidental shrinkage guard)

    @Test("Count per group matches the ported Mole rows")
    func countsPerGroup() {
        let byGroup = Dictionary(grouping: MoleTables.allTargets, by: \.group)
        #expect(byGroup[.userEssentials]?.count == 17)
        #expect(byGroup[.appCaches]?.count == 37)
        #expect(byGroup[.browsers]?.count == 114)
        #expect(byGroup[.guiApps]?.count == 187)
        #expect(byGroup[.developerTools]?.count == 60)
        #expect(byGroup[.cloudOffice]?.count == 21)
        #expect(byGroup[.systemPaths]?.count == 16)
        #expect(byGroup[.virtualization]?.count == 11)
        #expect(byGroup[.firmware]?.count == 4)
        #expect(byGroup[.timeMachine]?.count == 2)
        // Every declared group is non-zero — no empty sections.
        for group in MoleGroup.allCases {
            let count = byGroup[group]?.count ?? 0
            #expect(count > 0, "group \\(group.rawValue) has no rows")
        }
    }

    @Test("Aggregate table equals the sum of its parts")
    func aggregateMatchesSum() {
        let sum = Self.tables.reduce(0) { $0 + $1.rows.count }
        #expect(MoleTables.allTargets.count == sum)
    }
}
