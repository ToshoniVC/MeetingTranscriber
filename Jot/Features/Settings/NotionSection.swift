import SwiftUI
import AppKit

/// PRD §4.1: Notion configuration lives under Settings — toggle, token,
/// database ID, plus a Test connection button. Following the same shape
/// as `APIConfigSection`.
///
/// When the toggle is OFF, the controls below stay visible but dimmed so
/// the user can see what they'd need to fill in. The pipeline never calls
/// Notion unless `NotionValidation.validate(...)` returns `.ready`.
struct NotionSection: View {
    @Environment(AppSettings.self) private var settings

    /// Mirror of the Keychain-stored token so `SecureField` has something
    /// to bind to. Syncs to `AppSettings.notionToken` on every keystroke
    /// (matches the apiKey pattern).
    @State private var tokenDraft: String = ""

    /// Most recent Test connection outcome, or nil if not yet run.
    @State private var testFeedback: TestFeedback?

    /// True while a Test connection call is in flight.
    @State private var isTesting = false

    var body: some View {
        @Bindable var bindable = settings

        SectionHeader(
            title: "Notion",
            systemImage: "doc.text.below.ecg",
            subtitle: "Optional: create a Notion page for every transcribed meeting."
        )

        VStack(alignment: .leading, spacing: 16) {
            LabeledField(label: "Enable") {
                Toggle("Create a Notion page after each transcript", isOn: $bindable.notionEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: settings.notionEnabled) { _, newValue in
                        Log.notion.info("Notion meeting creation \(newValue ? "enabled" : "disabled", privacy: .public)")
                    }
            }

            LabeledField(label: "Token") {
                SecureField("paste your Notion integration token", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: tokenDraft) { _, newValue in
                        settings.notionToken = newValue.isEmpty ? nil : newValue
                    }
                    .disabled(!settings.notionEnabled)
            }

            LabeledField(label: "Database ID") {
                TextField(
                    "paste the database ID (the 32-char hex segment from its URL)",
                    text: $bindable.notionDatabaseId
                )
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .disabled(!settings.notionEnabled)
            }

            HStack(spacing: 8) {
                Button {
                    runTest()
                } label: {
                    if isTesting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Connecting…")
                        }
                    } else {
                        Text("Test connection")
                    }
                }
                .disabled(isTesting || !canTest)

                Button {
                    openHelpURL()
                } label: {
                    Label("How to set up", systemImage: "questionmark.circle")
                }
                .buttonStyle(.borderless)
            }

            statusLine
                .font(.caption)

            if let feedback = testFeedback {
                feedbackView(for: feedback)
            }
        }
        .opacity(settings.notionEnabled ? 1.0 : 0.6)
        .onAppear {
            tokenDraft = settings.notionToken ?? ""
        }
    }

    // MARK: - Status line

    /// Driven by `NotionValidation.validate(...)`. Shown below the controls
    /// so the user sees at a glance whether saving the section was enough.
    @ViewBuilder
    private var statusLine: some View {
        let status = NotionValidation.validate(settings)
        switch status {
        case .disabled:
            Text("Disabled.")
                .foregroundStyle(.secondary)
        case .misconfigured(let reason):
            Label("Setup needed: \(reason)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .ready:
            Label("Ready. Click Test connection to verify.", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
    }

    // MARK: - Test connection

    /// Only enabled when validation returns `.ready` — i.e., toggle on,
    /// token present, databaseId well-formed.
    private var canTest: Bool {
        if case .ready = NotionValidation.validate(settings) { return true }
        return false
    }

    private func runTest() {
        guard case .ready(let config) = NotionValidation.validate(settings) else { return }
        isTesting = true
        testFeedback = nil

        Task { @MainActor in
            defer { isTesting = false }
            let client = NotionClient()
            do {
                let info = try await client.describeDatabase(config: config)
                let displayName = info.title.isEmpty ? "(untitled)" : info.title
                testFeedback = .success(databaseName: displayName)
                Log.notion.info("Test connection succeeded — database \"\(displayName, privacy: .private)\"")
            } catch let error as NotionError {
                testFeedback = .failure(message: error.userFacingMessage)
                Log.notion.error("Test connection failed: \(error.userFacingMessage, privacy: .public)")
            } catch {
                testFeedback = .failure(message: error.localizedDescription)
                Log.notion.error("Test connection failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func openHelpURL() {
        // Notion's docs page for creating an internal integration. Letting
        // the user open this in their default browser via NSWorkspace keeps
        // us out of the link-clickability gray area in SwiftUI Forms.
        if let url = URL(string: "https://www.notion.so/profile/integrations") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Feedback

    private enum TestFeedback {
        case success(databaseName: String)
        case failure(message: String)
    }

    @ViewBuilder
    private func feedbackView(for feedback: TestFeedback) -> some View {
        switch feedback {
        case .success(let name):
            Label("Connected · \(name)", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
