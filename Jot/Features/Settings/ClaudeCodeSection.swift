import SwiftUI
import AppKit

/// PRD §4.1 + §4.2: Claude Code post-Notion routine trigger configuration.
/// Mirrors `NotionSection`'s shape — toggle, secure token, endpoint, an
/// optional extra-text field, plus an in-app setup guide and a test
/// checklist so the user can complete the external prerequisites without
/// leaving the app.
///
/// When the toggle is OFF the controls stay visible but dimmed so the
/// user can see what they'd need to fill in. The pipeline never fires
/// the routine unless `ClaudeCodeValidation.validate(...)` returns
/// `.ready`.
struct ClaudeCodeSection: View {
    @Environment(AppSettings.self) private var settings

    /// Mirror of the Keychain-stored token so `SecureField` has something
    /// to bind to. Syncs to `AppSettings.claudeCodeToken` on every
    /// keystroke — same pattern as `NotionSection` uses for `notionToken`.
    @State private var tokenDraft: String = ""

    /// Whether the in-app setup guide is expanded. Collapsed by default so
    /// the section doesn't dominate the Settings tab once the user has
    /// finished setup.
    @State private var setupExpanded: Bool = false

    var body: some View {
        @Bindable var bindable = settings

        SectionHeader(
            title: "Claude Code meeting notes",
            systemImage: "wand.and.stars",
            subtitle: "Optional: after each Notion page is created, fire a Claude Code routine to fill in the Meeting Notes section."
        )

        VStack(alignment: .leading, spacing: 16) {
            LabeledField(label: "Enable") {
                Toggle("Fire the Claude Code routine after each Notion page", isOn: $bindable.claudeCodeNotesEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: settings.claudeCodeNotesEnabled) { _, newValue in
                        Log.claudeCode.info("Claude Code routine trigger \(newValue ? "enabled" : "disabled", privacy: .public)")
                    }
            }

            LabeledField(label: "Endpoint") {
                TextField(
                    "https://api.anthropic.com/v1/claude_code/routines/<trigger_id>/fire",
                    text: $bindable.claudeCodeEndpoint
                )
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .disabled(!settings.claudeCodeNotesEnabled)
            }

            LabeledField(label: "Token") {
                SecureField("paste your Claude Code API token", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: tokenDraft) { _, newValue in
                        settings.claudeCodeToken = newValue.isEmpty ? nil : newValue
                    }
                    .disabled(!settings.claudeCodeNotesEnabled)
            }

            LabeledField(label: "Extra text") {
                TextField(
                    "optional — appended to the routine fire body as \"text\"",
                    text: $bindable.claudeCodeExtraText,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .disabled(!settings.claudeCodeNotesEnabled)
            }

            HStack(spacing: 8) {
                Button {
                    setupExpanded.toggle()
                } label: {
                    Label(setupExpanded ? "Hide setup guide" : "How to set up", systemImage: "questionmark.circle")
                }
                .buttonStyle(.borderless)

                Button {
                    openClaudeCodeURL()
                } label: {
                    Label("Open Claude Code", systemImage: "safari")
                }
                .buttonStyle(.borderless)
            }

            statusLine
                .font(.caption)

            if setupExpanded {
                setupGuide
            }
        }
        .opacity(settings.claudeCodeNotesEnabled ? 1.0 : 0.6)
        .onAppear {
            tokenDraft = settings.claudeCodeToken ?? ""
        }
    }

    // MARK: - Status line

    @ViewBuilder
    private var statusLine: some View {
        switch ClaudeCodeValidation.validate(settings) {
        case .disabled:
            Text("Disabled.")
                .foregroundStyle(.secondary)
        case .misconfigured(let reason):
            Label("Setup needed: \(reason)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .ready:
            // Explicitly remind the user that Notion still has to be
            // configured — the routine has nothing to write into without
            // a Notion page.
            switch NotionValidation.validate(settings) {
            case .ready:
                Label("Ready. The routine fires after each Notion page is created.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            default:
                Label("Configured, but Notion isn't set up — the routine has no page to write into.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Setup guide

    /// In-app guidance matching PRD §4.2. Plain text (no Markdown) so it
    /// works with macOS 14 Text rendering without an attributed-string
    /// dance. Includes a short test checklist so the user can verify the
    /// integration once configured.
    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up Claude Code")
                .font(.callout.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                guideStep(number: 1, text: "Create or choose a Claude Code routine that can access Notion and write into the target meeting page.")
                guideStep(number: 2, text: "Copy the routine fire endpoint URL (format: /v1/claude_code/routines/<trigger_id>/fire) into the Endpoint field above.")
                guideStep(number: 3, text: "Create or copy an API token with permission to fire the routine, paste it into the Token field above.")
                guideStep(number: 4, text: "Confirm Notion is already configured in Jot and meeting pages are being created.")
                guideStep(number: 5, text: "Optionally add extra instruction text — it's appended as the routine body's \"text\" field.")
            }

            Text("Test checklist")
                .font(.callout.weight(.semibold))
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                checklistItem("Trigger a test meeting.")
                checklistItem("Verify Jot creates the Notion page.")
                checklistItem("Verify Jot sends the Claude Code fire call (Audit Log row shows Notes: fired).")
                checklistItem("Verify Claude Code writes notes into the Notion page.")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func guideStep(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }

    private func checklistItem(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.square")
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .font(.callout)
        }
    }

    // MARK: - Links

    private func openClaudeCodeURL() {
        if let url = URL(string: "https://www.anthropic.com/claude-code") {
            NSWorkspace.shared.open(url)
        }
    }
}
