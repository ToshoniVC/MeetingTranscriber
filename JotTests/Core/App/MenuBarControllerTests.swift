import Testing
@testable import Jot

/// Unit tests for `MenuBarController` — the small, headless state object that
/// owns the menu-bar surface (Core/App/MenuBarController.swift).
///
/// Phase 0 surface is intentionally tiny (one Bool + 3 mutators). These tests
/// pin the contract so Phase 5 (Pipeline wiring) and Phase 8 (custom
/// `NSStatusItem`) build on a stable foundation.
@MainActor
struct MenuBarControllerTests {

    @Test
    func init_isMainWindowVisible_defaultsToFalse() {
        let controller = MenuBarController()
        #expect(controller.isMainWindowVisible == false)
    }

    @Test
    func showMainWindow_setsVisibleTrue() {
        let controller = MenuBarController()
        controller.showMainWindow()
        #expect(controller.isMainWindowVisible == true)
    }

    @Test
    func showMainWindow_isIdempotent() {
        let controller = MenuBarController()
        controller.showMainWindow()
        controller.showMainWindow()
        #expect(controller.isMainWindowVisible == true)
    }

    @Test
    func hideMainWindow_setsVisibleFalse() {
        let controller = MenuBarController()
        controller.showMainWindow()
        controller.hideMainWindow()
        #expect(controller.isMainWindowVisible == false)
    }

    @Test
    func hideMainWindow_isIdempotent() {
        let controller = MenuBarController()
        controller.hideMainWindow()
        controller.hideMainWindow()
        #expect(controller.isMainWindowVisible == false)
    }

    @Test
    func toggleMainWindow_flipsVisibility() {
        let controller = MenuBarController()
        #expect(controller.isMainWindowVisible == false)
        controller.toggleMainWindow()
        #expect(controller.isMainWindowVisible == true)
        controller.toggleMainWindow()
        #expect(controller.isMainWindowVisible == false)
    }
}
