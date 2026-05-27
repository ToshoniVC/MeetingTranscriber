import Foundation

/// Typed errors thrown by `TranscriptionClient.transcribe(...)`.
///
/// Designed so the UI (Audit Log in Phase 5, Settings "Test connection" in
/// Phase 3+) can give the user an actionable message without parsing strings.
enum TranscriptionError: Error, Equatable {

    /// `baseURL` couldn't be parsed or has no scheme. User-correctable in
    /// the Settings tab.
    case invalidEndpoint(rawURL: String)

    /// Server returned 401/403. User-correctable in the Settings tab.
    case invalidAPIKey

    /// Server returned 413 Payload Too Large (or close equivalent) — the
    /// audio file exceeds the endpoint's limit (Groq is currently 40 MB,
    /// OpenAI 25 MB). The Pipeline (Phase 5) can surface this with a hint
    /// to compress / split the file.
    case fileTooLarge(limitHint: String?)

    /// Server returned some other non-success status. `body` is the truncated
    /// response payload — useful for the Audit Log's "Copy details" button.
    case serverError(status: Int, body: String)

    /// Network failure that's plausibly transient (lost connection, DNS,
    /// timeout). The client retries once before surfacing this.
    case transientNetwork(message: String)

    /// Request exceeded the 5-minute hard timeout.
    case timeout

    /// Response wasn't valid UTF-8 or wasn't parseable per the request's
    /// declared `response_format`. Should be vanishingly rare against
    /// real OpenAI-compatible endpoints.
    case malformedResponse

    /// Programmer error wrapped as a value so the actor doesn't need to
    /// crash the app. Surfaces in the audit log.
    case internalInconsistency(String)

    /// User-facing message used by the Audit Log and Settings UI. Keep these
    /// short and actionable — the full `body` lives in the audit log row's
    /// "Copy details" sheet.
    var userFacingMessage: String {
        switch self {
        case .invalidEndpoint(let raw):
            return "API Base URL is invalid (\(raw)). Check it in Settings."
        case .invalidAPIKey:
            return "API key was rejected. Check it in Settings."
        case .fileTooLarge(let hint):
            return hint.map { "Audio file too large (\($0))." } ?? "Audio file too large for the endpoint."
        case .serverError(let status, _):
            return "Server returned HTTP \(status)."
        case .transientNetwork(let message):
            return "Network error: \(message). Will retry once."
        case .timeout:
            return "Request timed out."
        case .malformedResponse:
            return "Server response wasn't a transcript."
        case .internalInconsistency(let detail):
            return "Internal error: \(detail)."
        }
    }
}

/// Maps an HTTP response to the right `TranscriptionError`, or returns `nil`
/// for a successful status (2xx). Exposed as a free function so the pure
/// mapping is unit-testable without standing up a full client.
enum TranscriptionErrorMapper {
    static func error(forStatus status: Int, bodyHint body: String = "") -> TranscriptionError? {
        switch status {
        case 200...299:
            return nil
        case 401, 403:
            return .invalidAPIKey
        case 413:
            // The hint is best-effort: a couple of endpoints include their
            // limit in the body. We pass through whatever's there.
            return .fileTooLarge(limitHint: body.isEmpty ? nil : body.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return .serverError(status: status, body: String(body.prefix(2_048)))
        }
    }

    /// Whether a given error should be retried once (network blips, timeouts)
    /// or surfaced immediately (4xx, malformed response).
    static func isRetryable(_ error: TranscriptionError) -> Bool {
        switch error {
        case .transientNetwork, .timeout:
            return true
        case .invalidEndpoint, .invalidAPIKey, .fileTooLarge, .serverError,
             .malformedResponse, .internalInconsistency:
            return false
        }
    }
}
