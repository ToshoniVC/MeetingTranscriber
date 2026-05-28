import Testing
import Foundation
@testable import Jot

/// Integration tests for `NotionClient` against a `MockURLProtocol`-backed
/// `URLSession`. Every test seeds a canned response, then asserts both the
/// outgoing request (URL, headers, body) and the typed result/error.
///
/// Serialized because `MockURLProtocol` carries class-level state.
@Suite(.serialized)
struct NotionClientIntegrationTests {

    // MARK: - Fixtures

    private static let databaseId = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
    private static let token = "secret_test_token"

    private static let config = NotionConfig(token: token, databaseId: databaseId)

    private static func httpResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        var allHeaders = headers
        allHeaders["Content-Type"] = allHeaders["Content-Type"] ?? "application/json"
        return HTTPURLResponse(
            url: URL(string: "https://api.notion.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: allHeaders
        )!
    }

    /// Canned `GET /v1/databases/{id}` body that's accepted by
    /// `NotionClient.describeDatabase(...)`.
    private static func databaseBody(
        titleText: String = "Meetings",
        titlePropertyName: String = "Name"
    ) -> Data {
        let json = """
        {
            "object": "database",
            "title": [{"plain_text": "\(titleText)"}],
            "properties": {
                "\(titlePropertyName)": {"type": "title"},
                "Date": {"type": "date"}
            }
        }
        """
        return Data(json.utf8)
    }

    /// Canned `POST /v1/pages` body that the client decodes into
    /// `CreatePageResponse`.
    private static func createdPageBody(
        pageId: String = "11111111-2222-3333-4444-555555555555",
        url: String = "https://www.notion.so/Meeting-page-11111111222233334444555555555555",
        toggleIds: (notes: String, transcript: String, context: String) = (
            "n1111111-1111-1111-1111-111111111111",
            "t2222222-2222-2222-2222-222222222222",
            "c3333333-3333-3333-3333-333333333333"
        )
    ) -> Data {
        let json = """
        {
            "object": "page",
            "id": "\(pageId)",
            "url": "\(url)",
            "children": [
                {
                    "id": "\(toggleIds.notes)",
                    "type": "toggle",
                    "toggle": {"rich_text": [{"plain_text": "Meeting Notes"}]}
                },
                {
                    "id": "\(toggleIds.transcript)",
                    "type": "toggle",
                    "toggle": {"rich_text": [{"plain_text": "Meeting Transcript"}]}
                },
                {
                    "id": "\(toggleIds.context)",
                    "type": "toggle",
                    "toggle": {"rich_text": [{"plain_text": "Additional Context"}]}
                }
            ]
        }
        """
        return Data(json.utf8)
    }

    // MARK: - describeDatabase

    @Test
    func describeDatabase_happyPath_returnsTitleAndProperty() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 200), Self.databaseBody(titleText: "Meetings"))
        }

        let client = NotionClient(session: MockURLSession.make())
        let info = try await client.describeDatabase(config: Self.config)

        #expect(info.title == "Meetings")
        #expect(info.titlePropertyName == "Name")
        // The fixture body declares a "Date" column — should be discovered.
        #expect(info.datePropertyName == "Date")

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.url?.path == "/v1/databases/\(Self.databaseId)")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(req.value(forHTTPHeaderField: "Notion-Version") == NotionConfig.defaultAPIVersion)
    }

    @Test
    func describeDatabase_withoutDateProperty_setsDatePropertyNameToNil() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let body = """
        {
            "object": "database",
            "title": [{"plain_text": "Meetings"}],
            "properties": {"Name": {"type": "title"}}
        }
        """
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 200), Data(body.utf8))
        }
        let client = NotionClient(session: MockURLSession.make())
        let info = try await client.describeDatabase(config: Self.config)
        #expect(info.datePropertyName == nil)
    }

    @Test
    func describeDatabase_setsHTTPMethod_toGET() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 200), Self.databaseBody())
        }
        let client = NotionClient(session: MockURLSession.make())
        _ = try await client.describeDatabase(config: Self.config)
        #expect(MockURLProtocol.requests.first?.httpMethod == "GET")
    }

    @Test
    func describeDatabase_with401_throwsUnauthorized() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 401), Data("{\"message\":\"bad token\"}".utf8))
        }

        let client = NotionClient(session: MockURLSession.make())
        await #expect(throws: NotionError.unauthorized) {
            _ = try await client.describeDatabase(config: Self.config)
        }
    }

    @Test
    func describeDatabase_with404_throwsDatabaseNotFound() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 404), Data())
        }
        let client = NotionClient(session: MockURLSession.make())
        await #expect(throws: NotionError.databaseNotFound) {
            _ = try await client.describeDatabase(config: Self.config)
        }
    }

    @Test
    func describeDatabase_with429_includesRetryAfter() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 429, headers: ["Retry-After": "42"]), Data())
        }
        let client = NotionClient(session: MockURLSession.make())
        do {
            _ = try await client.describeDatabase(config: Self.config)
            Issue.record("Expected throw")
        } catch let error as NotionError {
            #expect(error == .rateLimited(retryAfter: 42))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func describeDatabase_withMissingTitleProperty_throws() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let body = """
        {"object": "database", "title": [], "properties": {"Date": {"type": "date"}}}
        """
        MockURLProtocol.responder = { _ in
            (Self.httpResponse(status: 200), Data(body.utf8))
        }
        let client = NotionClient(session: MockURLSession.make())
        await #expect(throws: NotionError.missingTitleProperty) {
            _ = try await client.describeDatabase(config: Self.config)
        }
    }

    // MARK: - createMeetingPage

    @Test
    func createMeetingPage_happyPath_returnsPageURL_andSendsCorrectBody() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.responder = { req in
            if req.url?.path == "/v1/databases/\(Self.databaseId)" {
                return (Self.httpResponse(status: 200), Self.databaseBody())
            }
            if req.url?.path == "/v1/pages" {
                return (Self.httpResponse(status: 200), Self.createdPageBody())
            }
            return (Self.httpResponse(status: 500), Data())
        }

        let client = NotionClient(session: MockURLSession.make())
        let result = try await client.createMeetingPage(
            config: Self.config,
            meetingName: "Q3 Planning",
            transcript: "Hello world.",
            additionalContext: "Org context."
        )

        #expect(result.pageId == "11111111-2222-3333-4444-555555555555")
        #expect(result.url.absoluteString.contains("notion.so"))

        // Two requests: GET database, POST pages.
        #expect(MockURLProtocol.requests.count == 2)
        let pagesIndex = try #require(
            MockURLProtocol.requests.firstIndex(where: { $0.url?.path == "/v1/pages" })
        )
        let pagesRequest = MockURLProtocol.requests[pagesIndex]
        #expect(pagesRequest.httpMethod == "POST")
        #expect(pagesRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(pagesRequest.value(forHTTPHeaderField: "Notion-Version") == NotionConfig.defaultAPIVersion)
        #expect(pagesRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")

        // Body has the meeting name and all three section titles.
        let bodyString = String(data: MockURLProtocol.requestBodies[pagesIndex], encoding: .utf8) ?? ""
        #expect(bodyString.contains("Q3 Planning"))
        #expect(bodyString.contains(NotionPageBuilder.SectionTitle.meetingNotes))
        #expect(bodyString.contains(NotionPageBuilder.SectionTitle.meetingTranscript))
        #expect(bodyString.contains(NotionPageBuilder.SectionTitle.additionalContext))
        #expect(bodyString.contains("Hello world."))
        #expect(bodyString.contains("Org context."))
        #expect(bodyString.contains("\"database_id\":\"\(Self.databaseId)\""))

        // Date stamp: today's date in the local TZ should be embedded
        // under the "Date" property the fixture declares.
        let today = NotionPageBuilder.isoDateString(from: Date())
        #expect(bodyString.contains("\"start\":\"\(today)\""))
    }

    @Test
    func createMeetingPage_withoutDateColumn_omitsDateStamp() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let dbBody = """
        {
            "object": "database",
            "title": [{"plain_text": "Meetings"}],
            "properties": {"Name": {"type": "title"}}
        }
        """
        MockURLProtocol.responder = { req in
            if req.url?.path == "/v1/databases/\(Self.databaseId)" {
                return (Self.httpResponse(status: 200), Data(dbBody.utf8))
            }
            if req.url?.path == "/v1/pages" {
                return (Self.httpResponse(status: 200), Self.createdPageBody())
            }
            return (Self.httpResponse(status: 500), Data())
        }

        let client = NotionClient(session: MockURLSession.make())
        _ = try await client.createMeetingPage(
            config: Self.config,
            meetingName: "x",
            transcript: "y",
            additionalContext: "z"
        )
        let pagesIndex = try #require(
            MockURLProtocol.requests.firstIndex(where: { $0.url?.path == "/v1/pages" })
        )
        let bodyString = String(data: MockURLProtocol.requestBodies[pagesIndex], encoding: .utf8) ?? ""
        // No date property emitted when the database has no date column.
        #expect(!bodyString.contains("\"start\":"))
    }

    @Test
    func createMeetingPage_cachesDatabaseDescribe_acrossCalls() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.responder = { req in
            if req.url?.path == "/v1/databases/\(Self.databaseId)" {
                return (Self.httpResponse(status: 200), Self.databaseBody())
            }
            if req.url?.path == "/v1/pages" {
                return (Self.httpResponse(status: 200), Self.createdPageBody())
            }
            return (Self.httpResponse(status: 500), Data())
        }

        let client = NotionClient(session: MockURLSession.make())
        _ = try await client.createMeetingPage(
            config: Self.config,
            meetingName: "First",
            transcript: "x",
            additionalContext: ""
        )
        _ = try await client.createMeetingPage(
            config: Self.config,
            meetingName: "Second",
            transcript: "y",
            additionalContext: ""
        )

        // 1 describe (cached) + 2 page creates = 3 requests.
        #expect(MockURLProtocol.requests.count == 3)
        let dbRequests = MockURLProtocol.requests.filter { $0.url?.path == "/v1/databases/\(Self.databaseId)" }
        #expect(dbRequests.count == 1)
    }

    @Test
    func createMeetingPage_with401_throwsUnauthorized() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { req in
            if req.url?.path == "/v1/databases/\(Self.databaseId)" {
                return (Self.httpResponse(status: 401), Data())
            }
            return (Self.httpResponse(status: 200), Self.createdPageBody())
        }
        let client = NotionClient(session: MockURLSession.make())
        await #expect(throws: NotionError.unauthorized) {
            _ = try await client.createMeetingPage(
                config: Self.config,
                meetingName: "x",
                transcript: "y",
                additionalContext: "z"
            )
        }
    }

    // MARK: - Overflow appends

    @Test
    func createMeetingPage_withTranscriptOverflow_issuesPatchAppendCalls() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let toggleIds = (
            notes: "n1111111-1111-1111-1111-111111111111",
            transcript: "t2222222-2222-2222-2222-222222222222",
            context: "c3333333-3333-3333-3333-333333333333"
        )

        MockURLProtocol.responder = { req in
            if req.url?.path == "/v1/databases/\(Self.databaseId)" {
                return (Self.httpResponse(status: 200), Self.databaseBody())
            }
            if req.url?.path == "/v1/pages" {
                return (Self.httpResponse(status: 200), Self.createdPageBody(toggleIds: toggleIds))
            }
            if req.url?.path.hasPrefix("/v1/blocks/") == true {
                return (Self.httpResponse(status: 200), Data("{\"object\":\"list\"}".utf8))
            }
            return (Self.httpResponse(status: 500), Data())
        }

        // 150 chunks of ~1900 chars to force overflow past the 100-block cap.
        let noSpace = String(repeating: "a", count: 1_900)
        let bigTranscript = Array(repeating: noSpace, count: 150).joined(separator: " ")

        let client = NotionClient(session: MockURLSession.make())
        _ = try await client.createMeetingPage(
            config: Self.config,
            meetingName: "big",
            transcript: bigTranscript,
            additionalContext: ""
        )

        // 1 describe + 1 create + ≥1 patch onto the transcript toggle.
        let patches = MockURLProtocol.requests.filter {
            $0.httpMethod == "PATCH"
            && $0.url?.path == "/v1/blocks/\(toggleIds.transcript)/children"
        }
        #expect(patches.count >= 1)
    }
}
