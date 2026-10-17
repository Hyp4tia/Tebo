import Foundation
import Testing
@testable import Tebo

@Suite("Mole selection safety") @MainActor
struct MoleSelectionSafetyTests {
    @Test("A failed protection save keeps the last effective policy and exposes the error")
    func failedSaveRetainsPolicy() throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-save-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("whitelist")
        try "keep\n".write(to: file, atomically: true, encoding: .utf8)
        let state = AppState(whitelistURL: file)
        state.addWhitelist("invalid\nentry")
        #expect(state.whitelist == ["keep"])
        #expect(state.protectionError != nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep\n")
        state.reloadProtections()
        #expect(state.protectionError == nil)
        #expect(state.whitelist == ["keep"])
    }

    @Test("Refreshing changed protections invalidates Mole previews without changing Media")
    func protectionRefreshInvalidatesMole() throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-state-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("whitelist")
        try "old\n".write(to: file, atomically: true, encoding: .utf8)
        let state = AppState(whitelistURL: file)
        let clean = ScanResult(path: "/fixture/cache", sizeBytes: 1, category: "Cache", reason: "Preview")
        let media = ScanResult(path: "/fixture/media", sizeBytes: 1, category: "Media", reason: "Deferred")
        state.resultsByTab = ["clean": [clean], "duplicates": [media]]
        state.selectedIDs = [clean.id, media.id]
        try "new\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(state.refreshProtections() == nil)
        #expect(state.whitelist == ["new"])
        #expect(state.results(for: "clean").isEmpty)
        #expect(state.results(for: "duplicates") == [media])
        #expect(state.selectedIDs == [media.id])
    }

    @Test("Filtered recommendations clear hidden and manual Mole selections")
    func filteredSelectionIsExact() {
        let state = AppState()
        let shown = ScanResult(path: "/fixture/shown", sizeBytes: 1, category: "Cache", reason: "Eligible", recommendedForSelection: true)
        let hidden = ScanResult(path: "/fixture/hidden", sizeBytes: 2, category: "Cache", reason: "Eligible", recommendedForSelection: true)
        let manual = ScanResult(path: "/fixture/review", sizeBytes: 3, category: "Manual", reason: "Review")
        state.resultsByTab["clean"] = [shown, hidden, manual]
        state.selectAll(for: "clean")
        state.selectRecommended(for: "clean", visibleIDs: [shown.id])
        #expect(state.selectedIDs == [shown.id])
    }

    @Test("Select recommended replaces this Mole tab's selection and preserves other tabs")
    func replacesOnlyCurrentTab() {
        let state = AppState()
        let recommended = ScanResult(path: "/fixture/cache", sizeBytes: 10, category: "Cache", reason: "Eligible", recommendedForSelection: true)
        let manual = ScanResult(path: "/fixture/installer.dmg", sizeBytes: 20, category: "Installer", reason: "Review")
        let other = ScanResult(path: "/fixture/media", sizeBytes: 30, category: "Media", reason: "Deferred")
        state.resultsByTab["clean"] = [recommended, manual]
        state.resultsByTab["duplicates"] = [other]
        state.selectAll(for: "clean")
        state.select([other.id])
        state.selectRecommended(for: "clean")
        #expect(state.selectedIDs == [recommended.id, other.id])
    }
}
