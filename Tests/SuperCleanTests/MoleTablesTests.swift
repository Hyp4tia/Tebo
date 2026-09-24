import Foundation
import Testing
@testable import SuperClean

// MARK: - MoleTables tests
// The tables are DATA ported from tw93/Mole's bash (GPL-3.0). These tests pin
// the invariants a scanner depends on: complete rows, traceable sources,
// unique paths per table, nothing pointing at system territory, everything
// resolving under the current user's home, and a stable count per group so
// accidental table shrinkage fails the build.
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

    // MARK: - Table shape

    @Test("Every table is non-empty")
    func tablesNonEmpty() {
        #expect(!UserEssentials.all.isEmpty)
        #expect(!AppCaches.all.isEmpty)
        #expect(!Browsers.all.isEmpty)
        #expect(!GuiApps.all.isEmpty)
    }

    @Test("Every row has label, group, explanation and source")
    func rowsComplete() {
        for (table, group) in [
            (UserEssentials.all, MoleGroup.userEssentials),
            (AppCaches.all, MoleGroup.appCaches),
            (Browsers.all, MoleGroup.browsers),
            (GuiApps.all, MoleGroup.guiApps),
        ] {
            for row in table {
                #expect(!row.label.isEmpty, "empty label in \(group.rawValue)")
                #expect(row.group == group, "\(row.label) in wrong group")
                #expect(!row.explanation.isEmpty, "no explanation for \(row.label)")
                #expect(!row.source.isEmpty, "no source for \(row.label)")
                #expect(row.source.hasPrefix("mole lib/clean/"), "unexpected source format: \(row.source)")
            }
        }
    }

    @Test("No duplicate paths within a table")
    func noDuplicatePaths() {
        for (table, name) in [
            (UserEssentials.all, "UserEssentials"),
            (AppCaches.all, "AppCaches"),
            (Browsers.all, "Browsers"),
            (GuiApps.all, "GuiApps"),
        ] {
            let raws = table.map { row -> String in
                switch row.path {
                case .homeRelative(let relative): return "~/" + relative
                case .absolute(let absolute): return absolute
                }
            }
            #expect(Set(raws).count == raws.count, "duplicate path in \(name): \(raws)")
        }
    }

    // MARK: - Safety

    @Test("No row points at a protected or critical system path")
    func noProtectedSystemPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedPrefixes = [
            "/System", "/Library", "/usr/", "/bin/", "/sbin/", "/etc/",
            "/private/var", "/private/etc", "/Volumes",
        ]
        for row in MoleTables.allTargets {
            let prefix = resolvedPrefix(row, home: home)
            #expect(!prefix.isEmpty, "\(row.label): empty resolved path")
            #expect(prefix != "/", "\(row.label): points at filesystem root")
            #expect(prefix != home, "\(row.label): points at the whole home directory")
            for protected in protectedPrefixes {
                #expect(
                    !prefix.hasPrefix(protected),
                    "\(row.label): protected path \(prefix) (source \(row.source))"
                )
            }
        }
    }

    @Test("Home-relative rows resolve under the current user's home")
    func homeRelativeRowsResolveUnderHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for table in [UserEssentials.all, AppCaches.all, Browsers.all, GuiApps.all] {
            for row in table {
                guard case .homeRelative = row.path else { continue }
                let prefix = resolvedPrefix(row, home: home)
                #expect(
                    prefix.hasPrefix(home + "/"),
                    "\(row.label): \(prefix) not under home (source \(row.source))"
                )
            }
        }
    }

    // MARK: - Counts (accidental shrinkage guard)

    @Test("Count per group matches the ported Mole rows")
    func countsPerGroup() {
        let byGroup = Dictionary(grouping: MoleTables.allTargets, by: \.group)
        #expect(byGroup[.userEssentials]?.count == 17)
        #expect(byGroup[.appCaches]?.count == 37)
        #expect(byGroup[.browsers]?.count == 43)
        #expect(byGroup[.guiApps]?.count == 79)
    }

    @Test("Aggregate table equals the sum of its parts")
    func aggregateMatchesSum() {
        let sum = UserEssentials.all.count + AppCaches.all.count
            + Browsers.all.count + GuiApps.all.count
        #expect(MoleTables.allTargets.count == sum)
    }
}
