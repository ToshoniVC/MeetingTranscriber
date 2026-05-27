import SwiftUI

/// PRD §3.2 Tab 3 → API Configuration:
/// - API Base URL (text)
/// - Model String (text)
/// - API Key (secure — Keychain-backed via `AppSettings.apiKey`)
/// - "Test connection" button (stub in Phase 1; wired in Phase 3 once
///   `TranscriptionClient` lands. We render the button so the UI layout is
///   stable and only swap the action in.)
struct APIConfigSection: View {
    @Environment(AppSettings.self) private var settings

    /// Mirror of the Keychain-stored API key so SwiftUI's `SecureField` has
    /// something to bind to. We sync on every keystroke (autosave matches the
    /// rest of `AppSettings`).
    @State private var apiKeyDraft: String = ""

    /// Local feedback for the (stubbed) Test connection action.
    @State private var testFeedback: String?

    var body: some View {
        @Bindable var bindable = settings

        SectionHeader(
            title: "API",
            systemImage: "network",
            subtitle: "Any OpenAI-compatible /audio/transcriptions endpoint — Groq, OpenAI, or a local Whisper server."
        )

        VStack(alignment: .leading, spacing: 16) {
            LabeledField(label: "Base URL") {
                TextField(
                    "https://api.groq.com/openai/v1/audio/transcriptions",
                    text: $bindable.apiBaseURL
                )
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .disableAutocorrection(true)
            }

            LabeledField(label: "Model") {
                TextField("whisper-large-v3", text: $bindable.modelString)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            LabeledField(label: "API Key") {
                SecureField("paste your API key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKeyDraft) { _, newValue in
                        settings.apiKey = newValue.isEmpty ? nil : newValue
                    }
            }

            HStack(spacing: 8) {
                Button("Test connection") {
                    // Phase 3 wires this to `TranscriptionClient.ping(...)`.
                    // Phase 1 stub: show a placeholder so the UI flow is
                    // exercisable end-to-end without a network round-trip.
                    testFeedback = "Test connection lands in Phase 3."
                }
                .disabled(settings.apiBaseURL.isEmpty
                          || settings.modelString.isEmpty
                          || (settings.apiKey ?? "").isEmpty)

                if let testFeedback {
                    Text(testFeedback)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // Surface whatever's currently in Keychain so the SecureField is
            // pre-populated on first display.
            apiKeyDraft = settings.apiKey ?? ""
        }
    }
}
