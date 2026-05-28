import Testing
import Foundation
@testable import Jot

/// Integration tests for `ClaudeCodeRoutineClient` against a
/// `MockURLProtocol`-backed `URLSession`. Each test seeds a canned response,
/// then asserts both the outgoing request (URL, headers, body) and the
/// typed result/error. Serialized because `MockURLProtocol` carries
/// class-level state.
@Suite(.serialized)
struct ClaudeCodeRoutineClientIntegrationTests {

    // MARK: - Fixtures

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/claude_code/routines/trg_abc/fire")!
    private static let token = "anthropic-bearer-token"

    private static func makeConfig(extraText: String = "") -> ClaudeCodeRoutineConfig {
        ClaudeCodeRoutineConfig(endpoint: endpoint, token: token, extraText: extraText)
    }

    private static func httpResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        var all = headers
        all["Content-Type"] = all["Content-Type"] ?? "application/json"
        return HTTPURLResponse(
            url: endpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: all
        )!
    }

    // MARK: - Happy path

    @Test
    func fire_sendsPOST_toConfiguredEndpoint() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 200), Data("{\"ok\": true}".utf8))
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        try await client.fire(config: Self.makeConfig(), text: "hello")

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.url == Self.endpoint)
        #expect(req.httpMethod == "POST")
    }

    @Test
    func fire_setsRequiredHeaders_exactlyAsPRD() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 200), Data("{}".utf8))
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        try await client.fire(config: Self.makeConfig(), text: "")

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(req.value(forHTTPHeaderField: "anthropic-version")
                == ClaudeCodeRoutineConfig.defaultAPIVersion)
        #expect(req.value(forHTTPHeaderField: "anthropic-beta")
                == ClaudeCodeRoutineConfig.defaultBetaHeader)
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func fire_bodyIsJSONWithTextField() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 200), Data("{}".utf8))
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        try await client.fire(config: Self.makeConfig(), text: "please write the notes")

        let body = MockURLProtocol.requestBodies.first ?? Data()
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["text"] as? String == "please write the notes")
    }

    @Test
    func fire_allowsEmptyText() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 200), Data("{}".utf8))
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        try await client.fire(config: Self.makeConfig(), text: "")
        let body = MockURLProtocol.requestBodies.first ?? Data()
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["text"] as? String == "")
    }

    // MARK: - Error path coverage

    @Test
    func fire_with401_throwsUnauthorized() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 401), Data("{\"error\":\"bad token\"}".utf8))
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        await #expect(throws: ClaudeCodeRoutineError.unauthorized) {
            try await client.fire(config: Self.makeConfig(), text: "")
        }
    }

    @Test
    func fire_with400_throwsBadRequest() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 400), Data("missing text".utf8))
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        do {
            try await client.fire(config: Self.makeConfig(), text: "")
            Issue.record("Expected throw")
        } catch let error as ClaudeCodeRoutineError {
            #expect(error == .badRequest(message: "missing text"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func fire_with404_throwsRoutineNotFound() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 404), Data())
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        await #expect(throws: ClaudeCodeRoutineError.routineNotFound) {
            try await client.fire(config: Self.makeConfig(), text: "")
        }
    }

    @Test
    func fire_with429_surfacesRetryAfter() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 429, headers: ["Retry-After": "17"]), Data())
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        do {
            try await client.fire(config: Self.makeConfig(), text: "")
            Issue.record("Expected throw")
        } catch let error as ClaudeCodeRoutineError {
            #expect(error == .rateLimited(retryAfter: 17))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func fire_with500_throwsServerError_noRetry() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 502), Data())
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        do {
            try await client.fire(config: Self.makeConfig(), text: "")
            Issue.record("Expected throw")
        } catch let error as ClaudeCodeRoutineError {
            #expect(error == .serverError(status: 502))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        // 5xx does NOT trigger a retry.
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test
    func fire_transportError_retriesOnce() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        // Always fail with a network error; client should attempt twice
        // total (initial + 1 retry).
        MockURLProtocol.responder = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        do {
            try await client.fire(config: Self.makeConfig(), text: "")
            Issue.record("Expected throw")
        } catch is ClaudeCodeRoutineError {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(MockURLProtocol.requests.count == 2)
    }

    @Test
    func fire_transportErrorThenSuccess_recovers() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.responder = { _ in
            calls += 1
            if calls == 1 { throw URLError(.timedOut) }
            return (Self.httpResponse(status: 200), Data("{}".utf8))
        }
        let client = ClaudeCodeRoutineClient(session: MockURLSession.make())
        try await client.fire(config: Self.makeConfig(), text: "")
        #expect(calls == 2)
    }
}
