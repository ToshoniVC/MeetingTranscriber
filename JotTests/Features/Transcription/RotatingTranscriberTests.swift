import Testing
import Foundation
@testable import Jot

/// Unit tests for `RotatingTranscriber`. Uses a fake `Transcribing`
/// (canned per-provider outcomes) and a fake `Source` (controlled
/// chain + keys) so the rotation logic is exercised without
/// URLProtocol or real networking.
@MainActor
struct RotatingTranscriberTests {

    // MARK: - Fakes

    /// Drives a scripted sequence of outcomes per provider — one
    /// `Result<TranscriptionResult, Error>` per call. Lets tests
    /// stage "first provider fails, second succeeds" without
    /// stubbing URLProtocol.
    private final class FakeTranscriber: RotatingTranscriber.Transcribing, @unchecked Sendable {

        struct Call: Equatable {
            let baseURL: URL
            let model: String
            let apiKey: String
        }

        var script: [Result<TranscriptionResult, Error>] = []
        private(set) var calls: [Call] = []
        private let lock = NSLock()

        func transcribe(
            audio: URL,
            baseURL: URL,
            model: String,
            apiKey: String,
            prompt: String?
        ) async throws -> TranscriptionResult {
            lock.lock()
            calls.append(Call(baseURL: baseURL, model: model, apiKey: apiKey))
            let next = script.isEmpty
                ? .failure(TranscriptionError.malformedResponse)
                : script.removeFirst()
            lock.unlock()
            switch next {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }

        static func result(text: String) -> TranscriptionResult {
            TranscriptionResult(
                text: text, duration: 1, segments: [], rawJSON: Data("{}".utf8)
            )
        }
    }

    private final class FakeSource: RotatingTranscriber.Source, @unchecked Sendable {
        var providers: [Provider] = []
        var keys: [UUID: String] = [:]

        func enabledOrdered() -> [Provider] {
            providers.filter(\.isEnabled).sorted { $0.sortOrder < $1.sortOrder }
        }
        func apiKey(for provider: Provider) -> String? { keys[provider.id] }
    }

    private static func provider(name: String, order: Int, enabled: Bool = true) -> Provider {
        Provider(
            displayName: name,
            baseURL: "https://api.\(name.lowercased()).com/v1/audio/transcriptions",
            model: "whisper-1",
            isEnabled: enabled,
            sortOrder: order
        )
    }

    private static func audioURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-rot-\(UUID().uuidString).mp3")
        try? Data("X".utf8).write(to: url)
        return url
    }

    // MARK: - Tests

    @Test
    func transcribe_firstProviderSucceeds_returnsAndStampsProviderName() async throws {
        let openai = Self.provider(name: "OpenAI", order: 0)
        let groq = Self.provider(name: "Groq", order: 1)

        let source = FakeSource()
        source.providers = [openai, groq]
        source.keys = [openai.id: "sk-openai", groq.id: "gsk_groq"]

        let client = FakeTranscriber()
        client.script = [.success(FakeTranscriber.result(text: "first"))]

        let rotator = RotatingTranscriber(client: client, source: source)
        let result = try await rotator.transcribe(audio: Self.audioURL())

        #expect(result.text == "first")
        #expect(result.providerName == "OpenAI")
        #expect(client.calls.count == 1, "Groq must not be called when OpenAI succeeded")
    }

    @Test
    func transcribe_firstFails_secondSucceeds_returnsSecondProviderName() async throws {
        let openai = Self.provider(name: "OpenAI", order: 0)
        let groq = Self.provider(name: "Groq", order: 1)

        let source = FakeSource()
        source.providers = [openai, groq]
        source.keys = [openai.id: "sk-openai", groq.id: "gsk_groq"]

        let client = FakeTranscriber()
        client.script = [
            .failure(TranscriptionError.timeout),
            .success(FakeTranscriber.result(text: "fallback"))
        ]

        let rotator = RotatingTranscriber(client: client, source: source)
        let result = try await rotator.transcribe(audio: Self.audioURL())

        #expect(result.text == "fallback")
        #expect(result.providerName == "Groq")
        #expect(client.calls.count == 2)
    }

    @Test
    func transcribe_allProvidersFail_throwsAllProvidersFailedWithLastMessage() async {
        let openai = Self.provider(name: "OpenAI", order: 0)
        let groq = Self.provider(name: "Groq", order: 1)

        let source = FakeSource()
        source.providers = [openai, groq]
        source.keys = [openai.id: "sk-openai", groq.id: "gsk_groq"]

        let client = FakeTranscriber()
        client.script = [
            .failure(TranscriptionError.timeout),
            .failure(TranscriptionError.invalidAPIKey)
        ]

        let rotator = RotatingTranscriber(client: client, source: source)
        do {
            _ = try await rotator.transcribe(audio: Self.audioURL())
            Issue.record("Expected throw")
        } catch let error as RotatingTranscriber.RotationError {
            if case .allProvidersFailed(let message, let attempts) = error {
                #expect(attempts == 2)
                #expect(message.contains("API key was rejected"),
                        "Last attempt's message should surface, got: \(message)")
            } else {
                Issue.record("Expected .allProvidersFailed, got \(error)")
            }
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test
    func transcribe_authError_doesCascade_perV045Policy() async throws {
        // v0.4.5 policy: ANY error cascades to the next provider,
        // including 4xx auth errors. This test pins the policy so a
        // future change to "auth surfaces immediately" must update
        // both the code AND this expectation deliberately.
        let openai = Self.provider(name: "OpenAI", order: 0)
        let groq = Self.provider(name: "Groq", order: 1)

        let source = FakeSource()
        source.providers = [openai, groq]
        source.keys = [openai.id: "sk-bad-openai", groq.id: "gsk_groq"]

        let client = FakeTranscriber()
        client.script = [
            .failure(TranscriptionError.invalidAPIKey),     // OpenAI 401
            .success(FakeTranscriber.result(text: "groq rescued"))
        ]

        let rotator = RotatingTranscriber(client: client, source: source)
        let result = try await rotator.transcribe(audio: Self.audioURL())
        #expect(result.text == "groq rescued")
        #expect(result.providerName == "Groq")
    }

    @Test
    func transcribe_skipsProviderWithoutKey_doesNotCountAsAttempt() async throws {
        let openai = Self.provider(name: "OpenAI", order: 0)
        let groq = Self.provider(name: "Groq", order: 1)

        let source = FakeSource()
        source.providers = [openai, groq]
        source.keys = [groq.id: "gsk_groq"]  // OpenAI has no key

        let client = FakeTranscriber()
        client.script = [.success(FakeTranscriber.result(text: "groq used"))]

        let rotator = RotatingTranscriber(client: client, source: source)
        let result = try await rotator.transcribe(audio: Self.audioURL())
        #expect(result.text == "groq used")
        #expect(result.providerName == "Groq")
        // OpenAI was skipped — only one call to the underlying client.
        #expect(client.calls.count == 1)
    }

    @Test
    func transcribe_noEnabledProviders_throwsNoEnabledProviders() async {
        let source = FakeSource()
        source.providers = []
        let client = FakeTranscriber()
        let rotator = RotatingTranscriber(client: client, source: source)

        do {
            _ = try await rotator.transcribe(audio: Self.audioURL())
            Issue.record("Expected throw")
        } catch RotatingTranscriber.RotationError.noEnabledProviders {
            // ok
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test
    func transcribe_invalidBaseURLProvider_isSkipped() async throws {
        var broken = Self.provider(name: "Broken", order: 0)
        broken.baseURL = "not a url"
        let good = Self.provider(name: "Groq", order: 1)

        let source = FakeSource()
        source.providers = [broken, good]
        source.keys = [broken.id: "k1", good.id: "k2"]

        let client = FakeTranscriber()
        client.script = [.success(FakeTranscriber.result(text: "ok"))]

        let rotator = RotatingTranscriber(client: client, source: source)
        let result = try await rotator.transcribe(audio: Self.audioURL())
        #expect(result.providerName == "Groq")
        #expect(client.calls.count == 1, "Broken provider must be skipped before reaching the client")
    }
}
