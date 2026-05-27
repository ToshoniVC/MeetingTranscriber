import SwiftUI
import AppKit

/// Banner + Setup expander shown at the top of `HotkeySection` when the
/// built-in recording flow is active. Two halves:
///
/// 1. **Installation banner.** Green if AH is installed (with path), orange
///    with a Download button if not.
/// 2. **Setup** (only when AH is installed). Disclosure group walking the
///    user through the one-time Shortcuts setup: AH session configured,
///    Start Shortcut authored, Stop Shortcut authored. Each item has an
///    action button.
struct AudioHijackBlock: View {
    @Environment(AudioHijackPresence.self) private var presence
    @Environment(AppSettings.self) private var settings

    @State private var isSetupExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            installationBanner
            if presence.isInstalled {
                DisclosureGroup(isExpanded: $isSetupExpanded) {
                    setupChecklist
                } label: {
                    Label("Setup", systemImage: "checklist")
                        .font(.callout.weight(.medium))
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(accentColor.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentColor.opacity(0.35), lineWidth: 1)
        }
    }

    // MARK: - Installation banner

    @ViewBuilder
    private var installationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(accentColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.callout.weight(.medium))
                if let path = subline {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if !presence.isInstalled {
                Button {
                    NSWorkspace.shared.open(AudioHijackPresence.downloadURL)
                } label: {
                    Label("Download Audio Hijack", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
            }

            Button {
                presence.refresh()
            } label: {
                Label("Recheck", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }

    // MARK: - Setup checklist

    @ViewBuilder
    private var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            checklistRow(
                number: 1,
                title: "Audio Hijack session configured",
                detail: "Open Audio Hijack and create at least one session. Pick your audio source (e.g., a Zoom/Meet window or your microphone) and add a Recorder block. Save the session and give it a name — your Shortcuts will reference it by that name.",
                actionTitle: "Open Audio Hijack",
                actionSystemImage: "waveform"
            ) {
                if let url = presence.url {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            checklistRow(
                number: 2,
                title: "\"\(settings.startShortcutName)\" Shortcut",
                detail: "In the Shortcuts app, create a Shortcut named exactly **\(settings.startShortcutName)**. Add the **Run/Stop Session** action from Audio Hijack, pick your session, and set **State** to **Running**. Optional: read **Shortcut Input** to use the meeting name Jot pipes in (e.g., for the recording filename).",
                actionTitle: "Open Shortcuts app",
                actionSystemImage: "command"
            ) {
                openShortcutsApp()
            }

            Divider()

            checklistRow(
                number: 3,
                title: "\"\(settings.stopShortcutName)\" Shortcut",
                detail: "Create a second Shortcut named exactly **\(settings.stopShortcutName)**. Add **Run/Stop Session**, pick the same session, and set **State** to **Stopped**. Jot calls this one when you press the hotkey while a recording is already running.",
                actionTitle: "Open Shortcuts app",
                actionSystemImage: "command"
            ) {
                openShortcutsApp()
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func checklistRow(
        number: Int,
        title: String,
        detail: String,
        actionTitle: String,
        actionSystemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                // Use Markdown rendering so the bolded Shortcut names in
                // `detail` stand out without us hand-rolling AttributedString.
                Text(.init(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    action()
                } label: {
                    Label(actionTitle, systemImage: actionSystemImage)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private func openShortcutsApp() {
        // `shortcuts://` URL scheme opens the macOS Shortcuts app.
        if let url = URL(string: "shortcuts://") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Presentation pieces

    private var accentColor: Color {
        presence.isInstalled ? .green : .orange
    }

    private var iconName: String {
        presence.isInstalled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var headline: String {
        presence.isInstalled
            ? "Audio Hijack is installed."
            : "Audio Hijack isn't installed — Jot needs it to record meetings."
    }

    private var subline: String? {
        presence.url?.path(percentEncoded: false)
    }
}
