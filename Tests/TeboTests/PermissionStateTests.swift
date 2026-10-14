import Testing
@testable import Tebo

@Suite("Permission status refresh") @MainActor
struct PermissionStateTests {
    @Test("A fresh access observation replaces both a stale denial and a revoked grant")
    func refreshAfterSettingsChange() async {
        let state = AppState()
        await state.refreshPermissions(probe: { false })
        #expect(state.hasFullDiskAccess == false)
        await state.refreshPermissions(probe: { true })
        #expect(state.hasFullDiskAccess == true)
        await state.refreshPermissions(probe: { false })
        #expect(state.hasFullDiskAccess == false)
    }
}
