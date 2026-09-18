import Testing
import Foundation
@testable import Jot

/// Integration tests for `HTTPSessionPolicy`: a session built through the
/// policy (HTTP/3 disabled) must still drive the real request path end to
/// end. Exercised through `TranscriptionClient` against a `MockURLProtocol`-
/// backed configuration — the same shape the production client uses, minus
/// the network.
///
/// Serialized because `MockURLProtocol` keeps its responder/recorder in
/// static state.
@Suite(.serialized)
struct HTTPSessionPolicyIntegrationTests {

    private static let baseURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    private static func makeAudio() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-policy-test-\(UUID().uuidString).mp3")
        try? Data("FAKE_AUDIO".utf8).write(to: url)
        return url
    }

    private static func makePolicySession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return HTTPSessionPolicy.makeSession(configuration: configuration)
    }

    @Test
    func transcriptionClient_overAPolicySession_roundTripsThroughURLProtocol() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"task":"transcribe","duration":1.0,"text":"policy ok","segments":[]}"#
            return (response, Data(body.utf8))
        }

        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let session = Self.makePolicySession()
        defer { session.finishTasksAndInvalidate() }

        let client = TranscriptionClient(session: session)
        let result = try await client.transcribe(
            audio: audio,
            baseURL: Self.baseURL,
            model: "whisper-large-v3",
            apiKey: "sk-test"
        )

        #expect(result.text == "policy ok")
        #expect(MockURLProtocol.requests.count == 1)
        #expect(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        // The opt-out survived URLSession's configuration copy (or is
        // reported unavailable on this OS — never silently half-applied).
        let expected: Bool? = HTTPSessionPolicy.http3OptOutAvailable ? true : nil
        #expect(HTTPSessionPolicy.isHTTP3Disabled(on: session.configuration) == expected)
    }

    @Test
    func transcriptionClient_overAPolicySession_stillMapsServerErrors() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }

        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let session = Self.makePolicySession()
        defer { session.finishTasksAndInvalidate() }

        let client = TranscriptionClient(session: session)
        await #expect(throws: TranscriptionError.invalidAPIKey) {
            _ = try await client.transcribe(
                audio: audio,
                baseURL: Self.baseURL,
                model: "whisper-large-v3",
                apiKey: "sk-wrong"
            )
        }
    }
}
