import Testing
import Foundation
@testable import Jot

/// Pure tests for `ClaudeCodeRoutineErrorMapper`. No URLSession involved.
/// Mirrors `NotionErrorMappingTests` in shape.
struct ClaudeCodeRoutineErrorMappingTests {

    @Test
    func mapper_returnsNil_for2xx() {
        for status in [200, 201, 202, 204, 299] {
            #expect(ClaudeCodeRoutineErrorMapper.error(forStatus: status) == nil)
        }
    }

    @Test
    func mapper_returnsUnauthorized_for401() {
        #expect(ClaudeCodeRoutineErrorMapper.error(forStatus: 401) == .unauthorized)
    }

    @Test
    func mapper_returnsBadRequest_for400() {
        let result = ClaudeCodeRoutineErrorMapper.error(forStatus: 400, bodyHint: "missing text field")
        #expect(result == .badRequest(message: "missing text field"))
    }

    @Test
    func mapper_returnsRoutineNotFound_for404() {
        #expect(ClaudeCodeRoutineErrorMapper.error(forStatus: 404) == .routineNotFound)
    }

    @Test
    func mapper_returnsRateLimited_for429_withRetryAfter() {
        let result = ClaudeCodeRoutineErrorMapper.error(forStatus: 429, retryAfter: 42)
        #expect(result == .rateLimited(retryAfter: 42))
    }

    @Test
    func mapper_returnsRateLimited_for429_withoutRetryAfter() {
        let result = ClaudeCodeRoutineErrorMapper.error(forStatus: 429)
        #expect(result == .rateLimited(retryAfter: nil))
    }

    @Test
    func mapper_returnsServerError_for5xx() {
        for status in [500, 502, 503, 504, 599] {
            #expect(ClaudeCodeRoutineErrorMapper.error(forStatus: status) == .serverError(status: status))
        }
    }

    @Test
    func mapper_returnsInvalidRequest_for403() {
        let result = ClaudeCodeRoutineErrorMapper.error(forStatus: 403, bodyHint: "no permission")
        #expect(result == .invalidRequest(status: 403, message: "no permission"))
    }

    @Test
    func userFacingMessages_includeStatusOrHint() {
        #expect(ClaudeCodeRoutineError.unauthorized.userFacingMessage.contains("token"))
        #expect(ClaudeCodeRoutineError.routineNotFound.userFacingMessage.contains("routine"))
        #expect(ClaudeCodeRoutineError.serverError(status: 502).userFacingMessage.contains("502"))
        let bad = ClaudeCodeRoutineError.badRequest(message: "missing text")
        #expect(bad.userFacingMessage.contains("missing text"))
    }
}
