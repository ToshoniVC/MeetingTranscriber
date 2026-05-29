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
        case .serverError(let status, let body):
            // v0.5.2: surface the first chunk of the server's response
            // body. Without this, the audit-log row reads "Server
            // returned HTTP 400" and we lose the actionable JSON
            // (`{"error":{"message":"..."}}`) OpenAI / Groq return.
            // Newlines collapsed to spaces so the row stays single-
            // line; capped at 300 chars to keep audit rows readable.
            let snippet = Self.normalizedBodySnippet(body)
            return snippet.isEmpty
                ? "Server returned HTTP \(status)."
                : "Server returned HTTP \(status): \(snippet)"
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

    /// Flatten newlines + tabs to single spaces, trim, cap to 300
    /// characters. Keeps the audit-log row readable when the body is
    /// multi-line JSON or HTML. Public-ish so the tests can pin the
    /// exact formatting rule.
    static func normalizedBodySnippet(_ body: String, maxLength: Int = 300) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Squeeze runs of spaces — bodies that came in as pretty-
        // printed JSON would otherwise be visually mangled.
        let squeezed = collapsed.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        if squeezed.count <= maxLength { return squeezed }
        return String(squeezed.prefix(maxLength)) + "…"
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
