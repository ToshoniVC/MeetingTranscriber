import SwiftUI
import AppKit

/// PRD §3.2 Tab 3 → System & Automation:
/// - Launch on Startup toggle
/// - Quit Jot button
///
/// The Launch on Startup toggle stores the user's intent in `AppSettings`.
/// The actual `SMAppService.mainApp.register()` call lives in Phase 7 (Core/
/// LoginItem/LoginItemManager.swift). For Phase 1 the toggle is wired to the
/// stored preference only — no system-level effect yet.
struct SystemSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var bindable = settings

        SectionHeader(
            title: "System",
            systemImage: "gearshape.2",
            subtitle: "Background launch behavior and how to exit Jot."
        )

        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $bindable.launchOnStartup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch on Startup")
                    Text("System-level registration via SMAppService lands in Phase 7.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            HStack {
                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit Jot", systemImage: "power")
                }
                Text("Fully exits the background daemon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
