import Testing
import Foundation
@testable import Jot

/// Integration tests for `TranscriptionClient` against a `MockURLProtocol`-
/// backed `URLSession`. Each case stages a canned HTTP response and asserts
/// what `client.transcribe(...)` returns or throws.
///
/// These tests run with `.serialized` so the shared `MockURLProtocol`
/// responder/recorder can't be clobbered by another concurrent test.
@Suite(.serialized)
struct TranscriptionClientIntegrationTests {

    // MARK: - Fixtures

    private static let baseURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    private static func makeAudio(content: String = "FAKE_AUDIO") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-client-test-\(UUID().uuidString).mp3")
        try? content.data(using: .utf8)!.write(to: url)
        return url
    }

    private static func okResponse(body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: baseURL, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"]
        )!
        return (response, Data(body.utf8))
    }

    private static func errorResponse(status: Int, body: String = "") -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: baseURL, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (response, Data(body.utf8))
    }

    // MARK: - Happy path

    @Test
    func successfulRequest_returnsTrimmedText() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "hello world\n") }

        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let client = TranscriptionClient(session: MockURLSession.make())
        let text = try await client.transcribe(
            audio: audio,
            baseURL: Self.baseURL,
            model: "whisper-large-v3",
            apiKey: "sk-test"
        )
        #expect(text == "hello world")
    }

    @Test
    func successfulRequest_capturesBearerAuthInRequest() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "ok") }

        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let client = TranscriptionClient(session: MockURLSession.make())
        _ = try await client.transcribe(
            audio: audio,
            baseURL: Self.baseURL,
            model: "whisper-large-v3",
            apiKey: "sk-magic-key"
        )

        let firstRequest = try #require(MockURLProtocol.requests.first)
        #expect(firstRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-magic-key")
        #expect(firstRequest.httpMethod == "POST")
        #expect(firstRequest.url == Self.baseURL)
    }

    // MARK: - Error mapping

    @Test
    func status401_throwsInvalidAPIKey() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.errorResponse(status: 401, body: "bad key") }

        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let client = TranscriptionClient(session: MockURLSession.make())
        await #expect(throws: TranscriptionError.invalidAPIKey) {
            _ = try await client.transcribe(
                audio: audio, baseURL: Self.baseURL,
                model: "m", apiKey: "sk-bad"
            )
        }
    }

    @Test
    func status413_throwsFileTooLarge() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.errorResponse(status: 413, body: "exceeds 40MB") }

        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let client = TranscriptionClient(session: MockURLSession.make())
        do {
            _ = try await client.transcribe(
                audio: audio, baseURL: Self.baseURL,
                model: "m", apiKey: "sk"
            )
            Issue.record("Expected throw")
        } catch let error as TranscriptionError {
            if case .fileTooLarge = error { /* ok */ } else {
                Issue.record("Expected .fileTooLarge, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func status500_throwsServerError() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.errorResponse(status: 500, body: "boom") }

        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let client = TranscriptionClient(session: MockURLSession.make())
        do {
            _ = try await client.transcribe(
                audio: audio, baseURL: Self.baseURL,
                model: "m", apiKey: "sk"
            )
            Issue.record("Expected throw")
        } catch let error as TranscriptionError {
            if case .serverError(let status, _) = error {
                #expect(status == 500)
            } else {
                Issue.record("Expected .serverError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Retry behavior

    @Test
    func transientNetworkError_isRetriedOnce() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        // Fail the first call with a network error, succeed on the second.
        var calls = 0
        MockURLProtocol.responder = { _ in
            calls += 1
            if calls == 1 {
                throw URLError(.networkConnectionLost)
            }
            return Self.okResponse(body: "second time worked")
        }

        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let client = TranscriptionClient(session: MockURLSession.make())
        let text = try await client.transcribe(
            audio: audio, baseURL: Self.baseURL,
            model: "m", apiKey: "sk"
        )
        #expect(text == "second time worked")
        #expect(MockURLProtocol.requests.count == 2)
    }

    @Test
    func authError_isNotRetried() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.errorResponse(status: 401) }

        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let client = TranscriptionClient(session: MockURLSession.make())
        await #expect(throws: TranscriptionError.invalidAPIKey) {
            _ = try await client.transcribe(
                audio: audio, baseURL: Self.baseURL,
                model: "m", apiKey: "sk-bad"
            )
        }
        #expect(MockURLProtocol.requests.count == 1, "4xx should NOT trigger retry")
    }

    @Test
    func persistentTransientError_failsAfterOneRetry() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            throw URLError(.networkConnectionLost)
        }

        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let client = TranscriptionClient(session: MockURLSession.make())
        do {
            _ = try await client.transcribe(
                audio: audio, baseURL: Self.baseURL,
                model: "m", apiKey: "sk"
            )
            Issue.record("Expected throw after retry")
        } catch let error as TranscriptionError {
            if case .transientNetwork = error { /* ok */ } else {
                Issue.record("Expected .transientNetwork, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(MockURLProtocol.requests.count == 2, "Should attempt original + 1 retry")
    }

    // MARK: - Input validation (no network)

    @Test
    func missingAudioFile_throwsInternalInconsistency() async {
        let client = TranscriptionClient(session: MockURLSession.make())
        let nonexistent = URL(fileURLWithPath: "/never/exists-\(UUID().uuidString).mp3")
        do {
            _ = try await client.transcribe(
                audio: nonexistent, baseURL: Self.baseURL,
                model: "m", apiKey: "sk"
            )
            Issue.record("Expected throw")
        } catch let error as TranscriptionError {
            if case .internalInconsistency = error { /* ok */ } else {
                Issue.record("Expected .internalInconsistency, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func emptyAPIKey_throwsInvalidAPIKeyWithoutNetworkCall() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let client = TranscriptionClient(session: MockURLSession.make())
        await #expect(throws: TranscriptionError.invalidAPIKey) {
            _ = try await client.transcribe(
                audio: audio, baseURL: Self.baseURL,
                model: "m", apiKey: ""
            )
        }
        #expect(MockURLProtocol.requests.isEmpty, "Validation should reject before sending")
    }
}
