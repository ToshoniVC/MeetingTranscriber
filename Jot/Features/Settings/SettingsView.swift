import SwiftUI

/// Root view for the Settings tab. Composes the sections defined by
/// PRD §3.2 Tab 3, plus the v0.4.5 multi-provider replacement of the
/// original API config section:
///   - `ProvidersSection`    (list of transcription providers with
///                            per-row enable / edit / reorder / delete;
///                            replaces the single-provider
///                            `APIConfigSection` shipped through v0.4.4)
///   - `FoldersSection`      (Watch + Output folder pickers)
///   - `HotkeySection`       (Recording hotkey recorder)
///   - `NotionSection`       (Notion bridge configuration)
///   - `ClaudeCodeSection`   (Claude Code post-Notion routine)
///   - `SystemSection`       (Launch on Startup, Quit Jot)
///
/// The window is hosted by `MainWindow` (Core/App) — see Phase 0. This view
/// receives `AppSettings` via the SwiftUI environment, wired in `JotApp`.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                ProvidersSection()
                Divider()
                FoldersSection()
                Divider()
                HotkeySection()
                Divider()
                NotionSection()
                Divider()
                ClaudeCodeSection()
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
