import Foundation
import Testing
@testable import SuperClean

// MARK: - SafetyGate tests
// Most important tests: a bug here = deleted user data.
// Run: swift test

@Suite("SafetyGate")
struct SafetyGateTests {

    @Test("Blocks system paths")
    func blocksSystem() {
        #expect(SafetyGate.isAllowed(path: "/System/Library/x", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "/Library/Updates/staged", whitelist: []) == false)
    }

    @Test("Respects whitelist")
    func respectsWhitelist() {
        let wl: Set<String> = ["com.myapp"]
        #expect(SafetyGate.isAllowed(path: "/Users/me/Library/Caches/com.myapp", whitelist: wl) == false)
        #expect(SafetyGate.isAllowed(path: "/Users/me/Library/Caches/other", whitelist: wl) == true)
    }

    @Test("Rejects root and empty")
    func rejectsRoot() {
        #expect(SafetyGate.isAllowed(path: "/", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "", whitelist: []) == false)
    }

    @Test("Expands ~ in whitelist entries")
    func expandsTilde() {
        // The Settings placeholder suggests ~/... paths — those must work.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let target = (home as NSString).appendingPathComponent("Library/Caches/com.myapp")
        #expect(SafetyGate.isAllowed(path: target, whitelist: ["~/Library/Caches/com.myapp"]) == false)
        #expect(SafetyGate.isAllowed(path: target, whitelist: ["~/Library/Caches/other"]) == true)
    }
}
