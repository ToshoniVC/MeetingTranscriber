import AppKit
import SwiftUI

/// Owns the menu-bar surface and (in later phases) translates `PipelineState`
/// into an icon-state animation per PRD §3.1.
///
/// **Phase 0 status:** placeholder. The menu-bar icon is currently declared
/// inline in `JotApp.swift` via SwiftUI's `MenuBarExtra`; this controller just
/// tracks a single `isMainWindowVisible` flag. Test coverage exists for the
/// flag's defaults and transitions so that Phase 5 / Phase 8 wiring has a
/// stable contract to build against.
///
/// **What lands later:**
/// - Phase 5 (Pipeline orchestrator): subscribe to `PipelineState` and expose
///   a derived `IconState` (idle / processing / error).
/// - Phase 8 (Icon state machine + UI polish): replace `MenuBarExtra` with a
///   custom `NSStatusItem` so a single click on the icon toggles the main
///   window directly (no dropdown), matching PRD §3.1.
///
/// Lives in `Core/App/` per Claude/coding-instructions.md §2: the menu-bar
/// surface is app-wide infrastructure, not a feature.
@MainActor
@Observable
final class MenuBarController {
    /// Whether the main window is currently requested to be visible.
    /// Phase 0 stub — flipped by the methods below; not yet wired to the
    /// actual SwiftUI `Window` scene's open/close lifecycle (that's Phase 8).
    private(set) var isMainWindowVisible: Bool = false

    init() {}

    /// Request that the main window become visible.
    func showMainWindow() {
        isMainWindowVisible = true
    }

    /// Request that the main window be hidden.
    func hideMainWindow() {
        isMainWindowVisible = false
    }

    /// Toggle the requested visibility — the click handler the Phase 8
    /// custom `NSStatusItem` will call.
    func toggleMainWindow() {
        isMainWindowVisible.toggle()
    }
}
