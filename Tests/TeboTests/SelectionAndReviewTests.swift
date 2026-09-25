import Foundation
import Testing

@testable import Tebo

// MARK: - SelectionPlan
// The selection buttons are the one place a user hands over judgement to the app, so the rules
// behind them are pinned here.

@Suite("SelectionPlan")
struct SelectionPlanTests {

    private func row(_ path: String, _ size: Int64) -> ScanResult {
        ScanResult(path: path, sizeBytes: size, category: "Test", reason: "test row")
    }

    @Test("One copy per group keeps the largest file of each group")
    func keepsLargestPerGroup() {
        let small = row("/tmp/a.png", 10)
        let large = row("/tmp/b.png", 5_000)
        let other = row("/tmp/c.png", 20)
        let groups: [UUID: String] = [small.id: "group-1", large.id: "group-1", other.id: "group-2"]

        let keepers = SelectionPlan.keepersByGroup(rows: [small, large, other], groups: groups)

        #expect(keepers == [large.id, other.id])
    }

    @Test("A single-file group keeps its only file")
    func singleRowGroupKeepsItsRow() {
        let only = row("/tmp/only.png", 1)
        let keepers = SelectionPlan.keepersByGroup(rows: [only], groups: [only.id: "g"])
        #expect(keepers == [only.id])
    }

    @Test("Rows the engine did not group are never keepers")
    func ungroupedRowsAreNotKeepers() {
        let orphan = row("/tmp/orphan.png", 9)
        let keepers = SelectionPlan.keepersByGroup(rows: [orphan], groups: [:])
        #expect(keepers.isEmpty)
    }

    @Test("Ties inside a group keep the first row seen, so the choice is stable")
    func tiesAreStable() {
        let first = row("/tmp/first.png", 100)
        let second = row("/tmp/second.png", 100)
        let groups: [UUID: String] = [first.id: "g", second.id: "g"]

        let keepers = SelectionPlan.keepersByGroup(rows: [first, second], groups: groups)

        #expect(keepers == [first.id])
    }

    @Test("The biggest rule returns the largest files, biggest first")
    func biggestReturnsLargestFirst() {
        let rows = [row("/tmp/a", 30), row("/tmp/b", 300), row("/tmp/c", 3)]
        #expect(SelectionPlan.biggest(2, in: rows) == [rows[1].id, rows[0].id])
    }

    @Test("A limit of zero or less selects nothing instead of everything")
    func zeroLimitSelectsNothing() {
        let rows = [row("/tmp/a", 30)]
        #expect(SelectionPlan.biggest(0, in: rows).isEmpty)
        #expect(SelectionPlan.biggest(-5, in: rows).isEmpty)
    }

    @Test("A limit larger than the list returns the whole list")
    func largeLimitReturnsEverything() {
        let rows = [row("/tmp/a", 30), row("/tmp/b", 3)]
        #expect(SelectionPlan.biggest(50, in: rows).count == 2)
    }
}

// MARK: - ReviewGrouping
// Kept-back entries are grouped for reading. Producers state the heading when they know it; the
// wording fallback exists because the orphan scanner's reasons are free text.

@Suite("ReviewGrouping")
struct ReviewGroupingTests {

    private func kept(_ reason: String, group: String = "") -> AdvisoryRow {
        AdvisoryRow(id: UUID().uuidString, title: "row", detail: reason, source: "kept: /tmp/x", group: group)
    }

    @Test("A heading from the producer wins over the wording")
    func producerHeadingWins() {
        let row = kept("Apple system agent; never offered as a leftover", group: "Reported only, nothing to delete")
        #expect(ReviewGrouping.heading(for: row) == "Reported only, nothing to delete")
    }

    @Test(
        "Orphan scanner reasons map to the headings a person would use",
        arguments: [
            ("Apple system agent; never offered as a leftover", "macOS system components"),
            ("Agent belongs to installed app com.foo.bar", "Used by an installed app"),
            ("Agent modified within the retention window", "Modified recently"),
            ("Agent program no longer exists: /usr/local/bin/gone", "Its program is missing"),
            ("Agent label com.foo is not a bundle identifier; ownership cannot be proven",
             "Ownership could not be proven"),
            ("Needs an administrator password, which Tebo never asks for. Not touched.",
             "Needs administrator rights"),
            ("Report only, nothing is deleted here", "Reported only, nothing to delete"),
            ("Something nobody has written a rule for", "Other entries kept"),
        ]
    )
    func reasonMapsToHeading(reason: String, expected: String) {
        #expect(ReviewGrouping.group(for: reason) == expected)
    }

    @Test("Groups are ordered by size, then by name")
    func groupsAreOrdered() {
        let rows = [
            kept("Apple system agent; never offered as a leftover"),
            kept("Apple system component; never offered as a leftover"),
            kept("Agent belongs to installed app com.foo.bar"),
        ]

        let groups = ReviewGrouping.groups(from: rows)

        #expect(groups.first?.title == "macOS system components")
        #expect(groups.first?.rows.count == 2)
        #expect(groups.last?.title == "Used by an installed app")
    }

    @Test("Rows inside a group are sorted by name")
    func rowsAreSortedInsideAGroup() {
        let rows = [
            AdvisoryRow(id: "2", title: "Zebra", detail: "Apple system agent", source: "s"),
            AdvisoryRow(id: "1", title: "anchor", detail: "Apple system component", source: "s"),
        ]

        let groups = ReviewGrouping.groups(from: rows)

        #expect(groups.first?.rows.map(\.title) == ["anchor", "Zebra"])
    }

    @Test("A kept path is read out of the advisory's source line")
    func keptPathIsExtracted() {
        let row = kept("Apple system agent")
        #expect(row.pathForThumb == "/tmp/x")
    }

    @Test("A table citation is not mistaken for a path")
    func citationIsNotAPath() {
        let row = AdvisoryRow(id: "x", title: "t", detail: "d", source: "lib/clean/user.sh:42")
        #expect(row.pathForThumb.isEmpty)
    }
}

// MARK: - Duplicate layouts
// Group maths feeds the grid and compare views, so it is checked without a window.

@Suite("Duplicate grouping")
@MainActor
struct DuplicateGroupingTests {

    private func row(_ path: String, _ size: Int64) -> ScanResult {
        ScanResult(path: path, sizeBytes: size, category: "Similar Images", reason: "row")
    }

    @Test("Rows group by the engine's group id, and ungrouped rows stay visible")
    func groupsByEngineID() {
        let a = row("/tmp/a.png", 100)
        let b = row("/tmp/b.png", 200)
        let lonely = row("/tmp/c.png", 50)
        let groups = [a.id: "g1", b.id: "g1"]

        let built = DuplicateRowsView.groups(
            rows: [a, b, lonely],
            groups: groups,
            details: [:]
        )

        #expect(built.count == 2)
        #expect(built.first?.rows.count == 2)
        #expect(built.last?.id == "ungrouped")
        #expect(built.last?.rows.map(\.path) == ["/tmp/c.png"])
    }

    @Test("Similarity comes from the engine's smallest difference in the group")
    func similarityFromSmallestDifference() {
        let a = row("/tmp/a.png", 100)
        let b = row("/tmp/b.png", 200)
        let details: [UUID: CzkawkaItemDetail] = [
            a.id: .similarImage(width: 100, height: 100, difference: 12),
            b.id: .similarImage(width: 100, height: 100, difference: 3),
        ]

        let built = DuplicateRowsView.groups(rows: [a, b], groups: [a.id: "g", b.id: "g"], details: details)

        // 3 of 40 allowed steps means 92% similar.
        #expect(built.first?.bestDifference == 3)
        #expect(built.first?.similarityPercent == 92)
    }

    @Test("The closest pair is the two images with the smallest differences")
    func closestPairUsesDifferences() {
        let close1 = row("/tmp/close1.png", 100)
        let close2 = row("/tmp/close2.png", 100)
        let far = row("/tmp/far.png", 100)
        let details: [UUID: CzkawkaItemDetail] = [
            close1.id: .similarImage(width: 10, height: 10, difference: 1),
            close2.id: .similarImage(width: 10, height: 10, difference: 2),
            far.id: .similarImage(width: 10, height: 10, difference: 30),
        ]
        let group = DuplicateRowsView.groups(
            rows: [far, close1, close2],
            groups: [far.id: "g", close1.id: "g", close2.id: "g"],
            details: details
        ).first

        #expect(group?.closestPair.map(\.path) == ["/tmp/close1.png", "/tmp/close2.png"])
        #expect(group?.remaining.map(\.path) == ["/tmp/far.png"])
    }

    @Test("Groups the engine does not score fall back to the two largest files")
    func unscoredGroupsUseLargest() {
        let big = row("/tmp/big.bin", 900)
        let middle = row("/tmp/middle.bin", 500)
        let small = row("/tmp/small.bin", 10)
        let group = DuplicateRowsView.groups(
            rows: [small, big, middle],
            groups: [small.id: "g", big.id: "g", middle.id: "g"],
            details: [:]
        ).first

        #expect(group?.closestPair.map(\.path) == ["/tmp/big.bin", "/tmp/middle.bin"])
    }

    @Test("Groups are ordered by total size, biggest first")
    func groupsOrderedBySize() {
        let smallA = row("/tmp/sa", 1)
        let smallB = row("/tmp/sb", 1)
        let bigA = row("/tmp/ba", 900)
        let bigB = row("/tmp/bb", 900)

        let built = DuplicateRowsView.groups(
            rows: [smallA, smallB, bigA, bigB],
            groups: [smallA.id: "small", smallB.id: "small", bigA.id: "big", bigB.id: "big"],
            details: [:]
        )

        #expect(built.map(\.id) == ["big", "small"])
    }
}
