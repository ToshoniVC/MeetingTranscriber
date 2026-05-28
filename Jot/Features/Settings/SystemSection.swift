import SwiftUI
import AppKit

/// PRD §3.2 Tab 3 → System & Automation:
/// - Launch on Startup toggle (registered via `SMAppService.mainApp` —
///   see `Core/LoginItem/LoginItemManager.swift`).
/// - Quit Jot button.
struct SystemSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LoginItemController.self) private var loginItem
    @Environment(SparkleUpdater.self) private var updater

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
                    Text(loginItem.statusMessage)
                        .font(.caption)
                        .foregroundStyle(loginItem.lastError == nil ? Color.secondary : Color.red)
                }
            }
            .toggleStyle(.switch)
            // Side-effect: every time the toggle flips, ask LoginItemManager
            // to actually register/unregister us with macOS.
            .onChange(of: settings.launchOnStartup) { _, newValue in
                loginItem.apply(enabled: newValue)
            }

            // Manual update check. The Sparkle controller also auto-checks
            // on launch and every 24h per Info.plist; this is the explicit
            // affordance from the implementation plan §8.6. Debug builds
            // get a stub updater whose canCheckForUpdates is always false,
            // so the button stays disabled in `Jot Dev`.
            HStack {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.down.circle")
                }
                .disabled(!updater.canCheckForUpdates)
                Text(updateButtonHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

    private var updateButtonHint: String {
        #if DEBUG
        return "Disabled in Jot Dev — ⌘R from Xcode to update the dev build."
        #else
        return updater.canCheckForUpdates
            ? "Jot also auto-checks on launch and every 24 hours."
            : "Checking…"
        #endif
    }
}
