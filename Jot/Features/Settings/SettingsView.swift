import SwiftUI

/// Root view for the Settings tab. Composes the four sections defined by PRD
/// §3.2 Tab 3:
///   - `APIConfigSection`    (Base URL, Model String, API Key, Test connection)
///   - `FoldersSection`      (Watch + Output folder pickers)
///   - `HotkeySection`       (Recording hotkey recorder)
///   - `SystemSection`       (Launch on Startup, Quit Jot)
///
/// The window is hosted by `MainWindow` (Core/App) — see Phase 0. This view
/// receives `AppSettings` via the SwiftUI environment, wired in `JotApp`.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                APIConfigSection()
                Divider()
                FoldersSection()
                Divider()
                HotkeySection()
                Divider()
                SystemSection()
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Settings")
    }
}
