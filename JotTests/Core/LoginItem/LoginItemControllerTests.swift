import Testing
import Foundation
@testable import Jot

/// Tests for `LoginItemController` against `FakeLoginItemControlling` so
/// no real `SMAppService.mainApp` registration happens.
@MainActor
struct LoginItemControllerTests {

    @Test
    func init_readsCurrentStatus() {
        let fake = FakeLoginItemControlling()
        fake.status = .enabled
        let controller = LoginItemController(manager: fake)
        #expect(controller.status == .enabled)
        #expect(controller.lastError == nil)
    }

    @Test
    func apply_true_callsSetEnabledTrue_andClearsError() {
        let fake = FakeLoginItemControlling()
        let controller = LoginItemController(manager: fake)
        controller.apply(enabled: true)
        #expect(fake.setEnabledCalls == [true])
        #expect(controller.status == .enabled)
        #expect(controller.lastError == nil)
    }

    @Test
    func apply_false_callsSetEnabledFalse() {
        let fake = FakeLoginItemControlling()
        fake.status = .enabled
        let controller = LoginItemController(manager: fake)
        controller.apply(enabled: false)
        #expect(fake.setEnabledCalls == [false])
        #expect(controller.status == .notRegistered)
    }

    @Test
    func apply_thrownError_setsLastError() {
        let fake = FakeLoginItemControlling()
        fake.nextSetEnabledError = LoginItemError.underlying("permission denied")
        let controller = LoginItemController(manager: fake)
        controller.apply(enabled: true)
        #expect(controller.lastError != nil)
        #expect(controller.lastError?.contains("permission") == true)
    }

    @Test
    func statusMessage_reflectsEnabledStatus() {
        let fake = FakeLoginItemControlling()
        let controller = LoginItemController(manager: fake)
        controller.apply(enabled: true) // fake sets status to .enabled
        #expect(controller.statusMessage.contains("launch at login"))
    }

    @Test
    func statusMessage_reflectsDisabledStatus() {
        let fake = FakeLoginItemControlling()
        fake.status = .notRegistered
        let controller = LoginItemController(manager: fake)
        #expect(controller.statusMessage.contains("Disabled"))
    }

    @Test
    func statusMessage_reflectsRequiresApprovalStatus() {
        // Build a controller whose initial status is .requiresApproval; we
        // don't call apply() because the fake's setEnabled clobbers the
        // status (good enough for normal flows, not for this case).
        let fake = FakeLoginItemControlling()
        fake.status = .requiresApproval
        let controller = LoginItemController(manager: fake)
        // Inspect the message that's exposed at init time.
        #expect(controller.status == .requiresApproval)
        #expect(controller.statusMessage.contains("Settings"))
    }

    @Test
    func statusMessage_prefersErrorMessageWhenSet() {
        let fake = FakeLoginItemControlling()
        fake.nextSetEnabledError = LoginItemError.underlying("nope")
        let controller = LoginItemController(manager: fake)
        controller.apply(enabled: true)
        #expect(controller.statusMessage.contains("nope"))
    }

    @Test
    func userFacingErrorMessages_areNonEmpty() {
        let error = LoginItemError.underlying("boom")
        #expect(!error.userFacingMessage.isEmpty)
    }
}
