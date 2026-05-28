import Testing
import Foundation
@testable import Jot

/// Pure HTTP-status-to-NotionError mapping. Every status the user-facing
/// surface cares about gets its own branch — these are the cases the
/// Settings "Test connection" feedback and audit-log row will display.
struct NotionErrorMappingTests {

    @Test
    func status200_isNoError() {
        #expect(NotionErrorMapper.error(forStatus: 200) == nil)
        #expect(NotionErrorMapper.error(forStatus: 299) == nil)
    }

    @Test
    func status401_mapsToUnauthorized() {
        #expect(NotionErrorMapper.error(forStatus: 401) == .unauthorized)
    }

    @Test
    func status404_mapsToDatabaseNotFound() {
        #expect(NotionErrorMapper.error(forStatus: 404) == .databaseNotFound)
    }

    @Test
    func status429_withoutRetryAfter_mapsToRateLimited_withNil() {
        #expect(NotionErrorMapper.error(forStatus: 429) == .rateLimited(retryAfter: nil))
    }

    @Test
    func status429_withRetryAfter_mapsToRateLimited_withValue() {
        #expect(
            NotionErrorMapper.error(forStatus: 429, retryAfter: 30)
            == .rateLimited(retryAfter: 30)
        )
    }

    @Test
    func status400_mapsToInvalidRequest_withBodyExcerpt() {
        let err = NotionErrorMapper.error(forStatus: 400, bodyHint: "bad request shape")
        #expect(err == .invalidRequest(status: 400, message: "bad request shape"))
    }

    @Test
    func status403_mapsToInvalidRequest() {
        let err = NotionErrorMapper.error(forStatus: 403, bodyHint: "no access")
        #expect(err == .invalidRequest(status: 403, message: "no access"))
    }

    @Test
    func status500_mapsToServerError() {
        #expect(NotionErrorMapper.error(forStatus: 500) == .serverError(status: 500))
        #expect(NotionErrorMapper.error(forStatus: 503) == .serverError(status: 503))
    }

    @Test
    func transportFromURLError_wrapsLocalizedDescription() {
        let urlError = URLError(.notConnectedToInternet)
        guard case .transport(let message) = NotionErrorMapper.transport(urlError) else {
            Issue.record("Expected .transport case")
            return
        }
        #expect(!message.isEmpty)
    }

    // MARK: - userFacingMessage smoke

    @Test
    func userFacingMessage_isNonEmpty_forEveryCase() {
        let cases: [NotionError] = [
            .unauthorized,
            .databaseNotFound,
            .rateLimited(retryAfter: nil),
            .rateLimited(retryAfter: 12),
            .invalidRequest(status: 400, message: "boom"),
            .serverError(status: 502),
            .transport(message: "offline"),
            .decoding(message: "bad json"),
            .missingTitleProperty,
            .internalInconsistency("oops")
        ]
        for c in cases {
            #expect(!c.userFacingMessage.isEmpty)
        }
    }
}
