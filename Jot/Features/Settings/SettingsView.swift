import SwiftUI

/// Phase 0 placeholder for the Settings tab.
///
/// Phase 1 (Claude/implementation-plan.md §2) replaces this with the real
/// configuration UI per PRD §3.2 Tab 3 — `APIConfigSection`, `FoldersSection`,
/// `HotkeySection`, `SystemSection`, all backed by `AppSettings` (in `Core/`)
/// with the API key in Keychain.
struct SettingsView: View {
    var body: some View {
        ContentUnavailableView(
            "Settings",
            systemImage: "gearshape",
            description: Text("API endpoint, folders, hotkey, and launch behavior will be configured here.\n(Implementation lands in Phase 1.)")
        )
    }
}
