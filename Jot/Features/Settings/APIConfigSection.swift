import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// PRD §3.2 Tab 3 → API Configuration:
/// - API Base URL (text)
/// - Model String (text)
/// - API Key (secure — Keychain-backed via `AppSettings.apiKey`)
/// - "Test connection" button: opens a file picker, sends the chosen audio
///   file to the configured endpoint via `TranscriptionClient`, displays
///   inline feedback. Needs a real audio file because OpenAI-compatible
///   `/audio/transcriptions` endpoints don't expose a payload-free ping.
struct APIConfigSection: View {
    @Environment(AppSettings.self) private var settings

    /// Mirror of the Keychain-stored API key so SwiftUI's `SecureField` has
    /// something to bind to. We sync on every keystroke (autosave matches the
    /// rest of `AppSettings`).
    @State private var apiKeyDraft: String = ""

    /// Result of the most recent "Test connection" attempt, or `nil` if it
    /// hasn't been run since the section appeared.
    @State private var testFeedback: TestFeedback?

    /// True while a "Test connection" call is in flight.
    @State private var isTesting = false

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
                .disabled(
                    isTesting
                    || settings.apiBaseURL.isEmpty
                    || settings.modelString.isEmpty
                    || (settings.apiKey ?? "").isEmpty
                )

                Text("Asks for a short audio file (mp3, m4a, or wav) and sends it to the configured endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let feedback = testFeedback {
                feedbackView(for: feedback)
            }
        }
        .onAppear {
            // Surface whatever's currently in storage so the SecureField is
            // pre-populated on first display.
            apiKeyDraft = settings.apiKey ?? ""
        }
    }

    // MARK: - Test connection

    /// Open a file picker and run a real transcription against the chosen
    /// file. UI feedback is updated on the main actor.
    private func runTest() {
        // Capture settings on the main actor before any async work.
        let baseURLString = settings.apiBaseURL
        let model = settings.modelString
        let apiKey = settings.apiKey ?? ""

        // File picker — synchronous; we're already on main.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav]
        panel.message = "Pick a short audio file to send to the transcription API."
        panel.prompt = "Test"

        guard panel.runModal() == .OK, let audioURL = panel.url else { return }

        guard let baseURL = URL(string: baseURLString), baseURL.scheme != nil else {
            testFeedback = .failure(message: "Base URL is invalid.")
            return
        }

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
                // The Test-connection panel shows what the user would
                // see in the Notion page — the timestamped rendering
                // when segments are available, plain text otherwise.
                let body = TimestampedTranscriptFormatter.formatBody(for: result)
                let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
                testFeedback = .success(transcript: cleaned, sourceFilename: audioURL.lastPathComponent)
            } catch let error as TranscriptionError {
                testFeedback = .failure(message: error.userFacingMessage)
            } catch {
                testFeedback = .failure(message: error.localizedDescription)
            }
        }
    }

    /// Result of a Test connection attempt. The success case carries the
    /// full transcript so the user can read and copy it.
    private enum TestFeedback {
        case success(transcript: String, sourceFilename: String)
        case failure(message: String)
    }

    // MARK: - Feedback rendering

    /// Renders either a one-line red error or a green-bordered transcript
    /// pane the user can read and copy. The transcript area is scrollable
    /// for long outputs and uses a monospaced font so whitespace is honest.
    @ViewBuilder
    private func feedbackView(for feedback: TestFeedback) -> some View {
        switch feedback {
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .success(let transcript, let filename):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(
                        "Connected — \(transcript.count) characters from \(filename)",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)

                    Spacer()

                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(transcript, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }

                ScrollView {
                    Text(transcript.isEmpty ? "(empty transcript)" : transcript)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.green.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.green.opacity(0.35), lineWidth: 1)
                )
            }
        }
    }
}
