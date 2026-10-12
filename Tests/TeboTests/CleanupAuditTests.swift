import Foundation
import Testing
@testable import Tebo

@Suite("File cleanup audit boundaries")
struct CleanupAuditTests {
    @Test("Changing scan locations clears stale rows, notes and selection, while retaining other tabs")
    @MainActor
    func changedScanScope() {
        let state = AppState()
        let previous = ScanResult(path: "/tmp/old-project/.build", sizeBytes: 4096, category: "Project", reason: "fixture")
        let other = ScanResult(path: "/tmp/cache", sizeBytes: 1024, category: "Clean", reason: "fixture")
        state.updateScanScope(["/tmp/old-project"], for: "purge")
        state.resultsByTab["purge"] = [previous]
        state.resultsByTab["clean"] = [other]
        state.advisoriesByTab["purge"] = [.init(id: "kept", title: "Kept", detail: "Nested repository", source: "/tmp/old-project/node_modules")]
        state.setScanNote("Previous scan", for: "purge")
        state.selectedIDs = [previous.id, other.id]
        #expect(!state.updateScanScope(["/tmp/old-project"], for: "purge"))
        #expect(state.results(for: "purge").count == 1)
        #expect(state.updateScanScope(["/tmp/new-project"], for: "purge"))
        #expect(state.resultsByTab["purge"] == nil)
        #expect(state.advisories(for: "purge").isEmpty)
        #expect(state.scanNote(for: "purge") == nil)
        #expect(state.selectedIDs == [other.id])
        #expect(state.results(for: "clean").count == 1)
    }

    @Test("A folder change discards the previous disk-usage report")
    @MainActor
    func changedAnalysisScope() {
        let state = AppState()
        state.updateScanScope(["/tmp/old"], for: "analyze")
        state.folderAnalysis = FolderAnalysis(path: "/tmp/old", entries: [], status: .complete)
        #expect(!state.updateScanScope(["/tmp/old"], for: "analyze"))
        #expect(state.folderAnalysis != nil)
        #expect(state.updateScanScope(["/tmp/new"], for: "analyze"))
        #expect(state.folderAnalysis == nil)
    }

    @Test("Whole user-data roots and credential trees stay protected while cache children remain available")
    func userDataRoots() {
        for relative in ["Library", "Library/Application Support", "Library/Containers", "Library/Group Containers",
                         "Library/Preferences", "Library/Caches", "Library/Logs", "Library/Saved Application State",
                         ".config", ".local", ".ssh/id_ed25519", ".gnupg/private-keys", "Library/Keychains/login.keychain-db"] {
            #expect(!SafetyGate.isAllowed(path: "/Users/fixture/\(relative)", whitelist: []))
        }
        #expect(SafetyGate.isAllowed(path: "/Users/fixture/Library/Caches/org.fixture.cache", whitelist: []))
        #expect(SafetyGate.isAllowed(path: "/Users/fixture/.config/fixture/cache", whitelist: []))
    }

    @Test("An absolute protected child also keeps its parent, without blocking siblings")
    func protectedChild() {
        let protected: Set<String> = ["/Users/fixture/Library/Caches/editor/important"]
        #expect(!SafetyGate.isAllowed(path: "/Users/fixture/Library/Caches/editor", whitelist: protected))
        #expect(!SafetyGate.isAllowed(path: "/Users/fixture/Library/Caches/editor/important/data", whitelist: protected))
        #expect(SafetyGate.isAllowed(path: "/Users/fixture/Library/Caches/editor-other", whitelist: protected))
    }

    @Test("A protected physical path cannot be bypassed through a symlinked parent")
    func whitelistAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tebo-audit-\(UUID())")
        let protected = root.appendingPathComponent("protected")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("kept".utf8).write(to: protected.appendingPathComponent("data"))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected)
        #expect(PathValidator.validate(path: alias.appendingPathComponent("data").path,
                                       whitelist: [protected.path]) == .whitelisted)
    }
}
