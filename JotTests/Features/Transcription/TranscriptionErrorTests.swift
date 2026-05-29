import Testing
import Foundation
@testable import Jot

/// Unit tests for `TranscriptionErrorMapper` — the pure mapping from HTTP
/// status code → typed `TranscriptionError`, and the retryability classifier.
struct TranscriptionErrorMapperTests {

    // MARK: - Status → error

    @Test
    func status200_returnsNil() {
        #expect(TranscriptionErrorMapper.error(forStatus: 200) == nil)
    }

    @Test
    func status299_returnsNil() {
        #expect(TranscriptionErrorMapper.error(forStatus: 299) == nil)
    }

    @Test
    func status401_returnsInvalidAPIKey() {
        let mapped = TranscriptionErrorMapper.error(forStatus: 401, bodyHint: "invalid_api_key")
        #expect(mapped == .invalidAPIKey)
    }

    @Test
    func status403_returnsInvalidAPIKey() {
        let mapped = TranscriptionErrorMapper.error(forStatus: 403, bodyHint: "")
        #expect(mapped == .invalidAPIKey)
    }

    @Test
    func status413_returnsFileTooLargeWithHint() {
        let mapped = TranscriptionErrorMapper.error(forStatus: 413, bodyHint: "file exceeds 25MB")
        if case .fileTooLarge(let hint) = mapped {
            #expect(hint == "file exceeds 25MB")
        } else {
            Issue.record("Expected .fileTooLarge, got \(String(describing: mapped))")
        }
    }

    @Test
    func status413_emptyBody_returnsFileTooLargeWithoutHint() {
        let mapped = TranscriptionErrorMapper.error(forStatus: 413, bodyHint: "")
        if case .fileTooLarge(let hint) = mapped {
            #expect(hint == nil)
        } else {
            Issue.record("Expected .fileTooLarge, got \(String(describing: mapped))")
        }
    }

    @Test
    func status500_returnsServerErrorWithStatusAndBody() {
        let body = "internal server error\n"
        let mapped = TranscriptionErrorMapper.error(forStatus: 500, bodyHint: body)
        if case .serverError(let status, let returnedBody) = mapped {
            #expect(status == 500)
            #expect(returnedBody == body)
        } else {
            Issue.record("Expected .serverError, got \(String(describing: mapped))")
        }
    }

    @Test
    func status429_returnsServerError() {
        // Rate-limiting maps to serverError (we don't have a separate case
        // for it — Pipeline can read the status and decide).
        let mapped = TranscriptionErrorMapper.error(forStatus: 429, bodyHint: "rate limit")
        if case .serverError(let status, _) = mapped {
            #expect(status == 429)
        } else {
            Issue.record("Expected .serverError, got \(String(describing: mapped))")
        }
    }

    @Test
    func serverError_truncatesBodyToReasonableSize() {
        let huge = String(repeating: "x", count: 10_000)
        let mapped = TranscriptionErrorMapper.error(forStatus: 502, bodyHint: huge)
        if case .serverError(_, let body) = mapped {
            #expect(body.count <= 2_048, "Body should be truncated to ~2KB")
        } else {
            Issue.record("Expected .serverError")
        }
    }

    // MARK: - Retryability

    @Test
    func retryable_includesTransientNetworkAndTimeout() {
        #expect(TranscriptionErrorMapper.isRetryable(.transientNetwork(message: "x")) == true)
        #expect(TranscriptionErrorMapper.isRetryable(.timeout) == true)
    }

    @Test
    func retryable_excludesAuth4xxAndMalformed() {
        #expect(TranscriptionErrorMapper.isRetryable(.invalidAPIKey) == false)
        #expect(TranscriptionErrorMapper.isRetryable(.invalidEndpoint(rawURL: "x")) == false)
        #expect(TranscriptionErrorMapper.isRetryable(.fileTooLarge(limitHint: nil)) == false)
        #expect(TranscriptionErrorMapper.isRetryable(.serverError(status: 500, body: "")) == false)
        #expect(TranscriptionErrorMapper.isRetryable(.malformedResponse) == false)
        #expect(TranscriptionErrorMapper.isRetryable(.internalInconsistency("x")) == false)
    }

    // MARK: - User-facing messages

    @Test
    func userFacingMessages_areNonEmpty() {
        let cases: [TranscriptionError] = [
            .invalidEndpoint(rawURL: "not-a-url"),
            .invalidAPIKey,
            .fileTooLarge(limitHint: "25MB"),
            .fileTooLarge(limitHint: nil),
            .serverError(status: 500, body: "boom"),
            .transientNetwork(message: "dns blew up"),
            .timeout,
            .malformedResponse,
            .internalInconsistency("widget unplugged")
        ]
        for error in cases {
            #expect(!error.userFacingMessage.isEmpty, "Empty message for \(error)")
        }
    }

    // MARK: - v0.5.2: server-error body in user-facing message

    @Test
    func serverError_userFacingMessage_includesBodySnippet() {
        let error = TranscriptionError.serverError(
            status: 400,
            body: #"{"error":{"message":"Invalid file format","type":"invalid_request_error"}}"#
        )
        let message = error.userFacingMessage
        #expect(message.contains("HTTP 400"))
        #expect(message.contains("Invalid file format"),
                "Expected the body's message to surface, got: \(message)")
    }

    @Test
    func serverError_userFacingMessage_emptyBody_keepsLegacyShape() {
        // Empty body → fall back to the v0.5.1-and-earlier wording so
        // tests / docs that match on "Server returned HTTP 400." still
        // line up.
        let error = TranscriptionError.serverError(status: 400, body: "")
        #expect(error.userFacingMessage == "Server returned HTTP 400.")
    }

    @Test
    func normalizedBodySnippet_collapsesNewlinesAndTabs() {
        let raw = "line one\r\nline two\n\tindented\n\nblank"
        let snippet = TranscriptionError.normalizedBodySnippet(raw)
        #expect(snippet == "line one line two indented blank")
    }

    @Test
    func normalizedBodySnippet_capsAtMaxLength() {
        let long = String(repeating: "a", count: 500)
        let snippet = TranscriptionError.normalizedBodySnippet(long, maxLength: 50)
        #expect(snippet.count == 51, "50 chars + ellipsis")
        #expect(snippet.hasSuffix("…"))
    }

    @Test
    func normalizedBodySnippet_emptyInput_returnsEmpty() {
        #expect(TranscriptionError.normalizedBodySnippet("") == "")
        #expect(TranscriptionError.normalizedBodySnippet("   \n  \t  ") == "")
    }
}
