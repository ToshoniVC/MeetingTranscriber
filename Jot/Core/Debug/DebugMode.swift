import Foundation
import Observation

/// Runtime flag for developer / verbose-logging mode.
///
/// Per Phase 8 of the implementation plan: a session-scoped toggle that turns
/// up the volume on diagnostics without requiring an Xcode build or
/// `log config --mode level:debug`. Two effects today:
///   1. Feature code can gate verbose `os.Logger` calls on `isVerbose` —
///      `if DebugMode.shared.isVerbose { Log.app.info("…") }`.
///   2. The menu-bar dropdown reveals a **Developer** submenu (open
///      Console.app, copy the `log show` command).
///
/// The plan describes this as "hidden ⌥-click on the menu-bar icon". SwiftUI's
/// `MenuBarExtra` can't detect modifier state at click time without dropping
/// to a custom `NSStatusItem`. Until that refactor lands, the toggle is
/// always visible as a menu item — same outcome, different affordance.
///
/// Not persisted: resets to `false` each launch on purpose. Verbose mode is
/// a diagnostic state, not a preference.
@MainActor
@Observable
final class DebugMode {
    /// `true` when verbose logging / developer affordances are active.
    var isVerbose: Bool = false

    init() {}

    /// Flip the flag. Bound to the menu-bar dropdown toggle.
    func toggle() {
        isVerbose.toggle()
    }
}
