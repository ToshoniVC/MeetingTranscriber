import Testing
import Foundation
@testable import Jot

/// Targeted tests for `PipelineCoordinator.dismissError()`. We don't fully
/// drive the coordinator's bootstrap/observation here — that's covered
/// end-to-end by `PipelineIntegrationTests`. These tests pin just the
/// dismissError contract because it's user-facing UI behavior.
@MainActor
struct PipelineCoordinatorTests {

    private func makeCoordinator() -> (coordinator: PipelineCoordinator, menuBar: MenuBarController) {
        let defaults = EphemeralUserDefaults.make()
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let auditLog = AuditLogStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("jot-coord-audit-\(UUID().uuidString).json")
        )
        let menuBar = MenuBarController()
        let coordinator = PipelineCoordinator(
            settings: settings,
            auditLog: auditLog,
            menuBar: menuBar
        )
        return (coordinator, menuBar)
    }

    @Test
    func dismissError_whenErrorState_andNoPipeline_setsNotConfigured() {
        let (coordinator, menuBar) = makeCoordinator()
        menuBar.iconState = .error(URL(fileURLWithPath: "/tmp/x.mp3"), "boom")
        coordinator.dismissError()
        #expect(menuBar.iconState == .notConfigured)
    }

    @Test
    func dismissError_whenNotInErrorState_isNoOp() {
        let (coordinator, menuBar) = makeCoordinator()

        menuBar.iconState = .idle
        coordinator.dismissError()
        #expect(menuBar.iconState == .idle)

        let url = URL(fileURLWithPath: "/tmp/x.mp3")
        menuBar.iconState = .processing(url)
        coordinator.dismissError()
        #expect(menuBar.iconState == .processing(url))

        menuBar.iconState = .notConfigured
        coordinator.dismissError()
        #expect(menuBar.iconState == .notConfigured)
    }
}
