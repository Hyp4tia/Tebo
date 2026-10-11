import Foundation
import Testing
@testable import Tebo

@Suite("Workspace activity") @MainActor
struct WorkspaceActivityTests {
    @Test("Dashboard counts successful Trash moves, excluding blocked and failed items")
    func reportsOnlySuccessfulRemovals() {
        let activity = WorkspaceActivity()
        activity.recordRemoval(DeleteReport(outcomes: [
            .init(path: "/tmp/first", result: .trashed(bytes: 1024)),
            .init(path: "/tmp/blocked", result: .skipped(reason: .missing)),
            .init(path: "/tmp/failed", result: .failed(message: "Permission denied"))
        ]))
        activity.recordRemoval(DeleteReport(outcomes: [
            .init(path: "/tmp/second", result: .trashed(bytes: 2048))
        ]))
        #expect(activity.trashedCount == 2)
        #expect(activity.trashedBytes == 3072)
    }

    @Test("A fresh session never claims a scan has run")
    func startsWithoutScanClaims() {
        let activity = WorkspaceActivity()
        #expect(activity.lastScan == nil)
        #expect(activity.scanDuration == nil)
        #expect(activity.trashedCount == 0)
        #expect(activity.trashedBytes == 0)
    }
}
