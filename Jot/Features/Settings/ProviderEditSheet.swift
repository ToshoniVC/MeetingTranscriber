import SwiftUI
import AppKit

/// Modal sheet for adding or editing a single `Provider`. Reuses the
/// same component for both flows — `ProvidersSection` passes a blank
/// draft to create a new provider, or an existing one to edit.
///
/// "Save" validates via `ProviderStore.upsert(...)`'s `ProviderValidation`
/// path and either dismisses with the saved provider or re-presents
/// with the validation error.
///
/// "Test connection" runs a real transcription through the provider's
/// `TranscriptionClient` against a user-picked audio file. Operates on
/// the live draft state so the user can verify before saving.
struct ProviderEditSheet: View {
    @Environment(ProviderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Editable mirror of the provider being edited. Bound to fields
    /// directly. `id` is preserved from the parent so save-on-edit
    /// updates the right record.
    @State private var draft: Provider

    /// The API key shown / typed in the SecureField. Synced from the
    /// keychain on appear; written back to the keychain on save.
    @State private var apiKeyDraft: String = ""

    /// Local error from the most recent save attempt — shown inline so
    /// the user can fix without losing their typed data.
    @State private var saveError: String?

    /// Most recent Test connection outcome.
    @State private var testFeedback: TestFeedback?

    /// True while a Test connection call is in flight.
    @State private var isTesting = false

    /// Closure invoked on save (with the saved provider) or cancel
    /// (with nil). `ProvidersSection` uses this to drive its sheet
    /// state and call `store.upsert(...)` only when the user confirms.
    private let onComplete: (Provider?) -> Void

    init(provider: Provider, onComplete: @escaping (Provider?) -> Void) {
        self._draft = State(initialValue: provider)
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Form {
                Section {
                    TextField("Display name", text: $draft.displayName, prompt: Text("OpenAI"))
                        .onChange(of: draft.baseURL) { _, newURL in
                            // Auto-populate the name field on first
                            // typing if the user hasn't named the
                            // provider yet — saves a step on the most
                            // common flow.
                            if draft.displayName.isEmpty {
                                draft.displayName = Provider.suggestedDisplayName(forBaseURL: newURL)
                            }
                        }
                    TextField(
                        "Base URL",
                        text: $draft.baseURL,
                        prompt: Text("https://api.openai.com/v1/audio/transcriptions")
                    )
                    .textContentType(.URL)
                    .disableAutocorrection(true)
                    TextField("Model", text: $draft.model, prompt: Text("whisper-1"))
                        .disableAutocorrection(true)
                    SecureField("API key", text: $apiKeyDraft, prompt: Text("paste your key"))
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        Button {
                            runTest()
                        } label: {
                            if isTesting {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Transcribing…")
                                }
                            } else {
                                Text("Test connection")
                            }
                        }
                        .disabled(isTesting || !canTest)

                        Text("Picks an audio file and runs it through this provider only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let feedback = testFeedback {
                    Section {
                        feedbackView(for: feedback)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 320)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onComplete(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            // Surface whatever's in the keychain so editing an existing
            // provider doesn't require re-pasting the key.
            apiKeyDraft = store.apiKey(for: draft) ?? ""
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isNew ? "Add provider" : "Edit provider")
                .font(.title3.weight(.semibold))
            Text("OpenAI-compatible `/audio/transcriptions` endpoint — OpenAI, Groq, or any other server speaking the same shape.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isNew: Bool {
        store.provider(id: draft.id) == nil
    }

    private var canTest: Bool {
        !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !apiKeyDraft.isEmpty
    }

    // MARK: - Save

    private func save() {
        // Persist key first so a save attempt with a fresh provider
        // includes the key in the same atomic operation from the
        // user's perspective. If upsert fails (validation), the key's
        // still in the keychain — that's fine, the next save retry
        // doesn't have to re-paste.
        store.setAPIKey(apiKeyDraft.isEmpty ? nil : apiKeyDraft, for: draft)
        do {
            let saved = try store.upsert(draft)
            saveError = nil
            onComplete(saved)
        } catch let error as ProviderValidationError {
            saveError = error.errorDescription
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Test connection

    private func runTest() {
        guard let baseURL = URL(string: draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              baseURL.scheme != nil
        else {
            testFeedback = .failure(message: "Base URL is invalid.")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav]
        panel.message = "Pick a short audio file to send to \(draft.displayName.isEmpty ? "the endpoint" : draft.displayName)."
        panel.prompt = "Test"

        guard panel.runModal() == .OK, let audioURL = panel.url else { return }

        let model = draft.model
        let apiKey = apiKeyDraft

        isTesting = true
        testFeedback = nil

        Task { @MainActor in
            defer { isTesting = false }
            do {
                let client = TranscriptionClient()
                let result = try await client.transcribe(
                    audio: audioURL,
                    baseURL: baseURL,
                    model: model,
                    apiKey: apiKey
                )
                let body = TimestampedTranscriptFormatter.formatBody(for: result)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                testFeedback = .success(transcript: body, sourceFilename: audioURL.lastPathComponent)
            } catch let error as TranscriptionError {
                testFeedback = .failure(message: error.userFacingMessage)
            } catch {
                testFeedback = .failure(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Feedback rendering

    private enum TestFeedback {
        case success(transcript: String, sourceFilename: String)
        case failure(message: String)
    }

    @ViewBuilder
    private func feedbackView(for feedback: TestFeedback) -> some View {
        switch feedback {
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        case .success(let transcript, let filename):
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "Connected — \(transcript.count) characters from \(filename)",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)

                ScrollView {
                    Text(transcript.isEmpty ? "(empty transcript)" : transcript)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 100)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.35), lineWidth: 1)
                )
            }
        }
    }
}
