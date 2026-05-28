import Foundation

/// Typed errors thrown by `ClaudeCodeRoutineClient`. Designed so the
/// audit log (and future Settings "Test fire" surface) can render a
/// one-line actionable message without string parsing. Mirrors
/// `NotionError` / `TranscriptionError` shape.
enum ClaudeCodeRoutineError: Error, Equatable, Sendable {

    /// 401 — bearer token was rejected.
    case unauthorized

    /// 400 — request body / headers were malformed. `message` is the
    /// server's error body summary (truncated), useful for debugging
    /// payload drift.
    case badRequest(message: String)

    /// 404 — endpoint URL didn't resolve to a known routine. Usually
    /// means the trigger ID in the URL is wrong or the routine has been
    /// deleted.
    case routineNotFound

    /// 429 — server is rate-limiting us. `retryAfter` is the server hint
    /// in seconds, or `nil` if the header was missing/unparseable.
    case rateLimited(retryAfter: TimeInterval?)

    /// 5xx — server problem. Not auto-retried beyond the single retry
    /// the client does on transport errors.
    case serverError(status: Int)

    /// DNS / connection / timeout failure.
    case transport(message: String)

    /// Other 4xx not covered above. `status` is the raw code; `message`
    /// is the (truncated) server error body summary.
    case invalidRequest(status: Int, message: String)

    /// Couldn't decode the server's response. The fire endpoint returns
    /// JSON we don't strictly need, but a body we can't parse at all
    /// usually means we're pointing at the wrong URL.
    case decoding(message: String)

    /// Programmer error (e.g., body encode failure). Surfaces in the
    /// audit log so a regression doesn't fail silently.
    case internalInconsistency(String)

    /// One-line user-facing summary suitable for the audit log row.
    var userFacingMessage: String {
        switch self {
        case .unauthorized:
            return "Claude Code token was rejected. Check it in Settings."
        case .badRequest(let message):
            return "Claude Code rejected the request: \(message)"
        case .routineNotFound:
            return "Claude Code routine not found — confirm the endpoint URL in Settings."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Claude Code rate-limited the request (retry in \(Int(retryAfter))s)."
            }
            return "Claude Code rate-limited the request."
        case .serverError(let status):
            return "Claude Code returned HTTP \(status)."
        case .transport(let message):
            return "Network error reaching Claude Code: \(message)"
        case .invalidRequest(let status, let message):
            return "Claude Code rejected the request (HTTP \(status)): \(message)"
        case .decoding(let message):
            return "Couldn't read Claude Code's response: \(message)"
        case .internalInconsistency(let detail):
            return "Internal error: \(detail)."
        }
    }
}

/// Pure mapping from HTTP status (+ best-effort body) to
/// `ClaudeCodeRoutineError`. Exposed so tests can hit it without
/// standing up a client.
enum ClaudeCodeRoutineErrorMapper {

    /// Returns nil for a 2xx status, or the right error case for
    /// everything else.
    static func error(
        forStatus status: Int,
        bodyHint body: String = "",
        retryAfter: TimeInterval? = nil
    ) -> ClaudeCodeRoutineError? {
        switch status {
        case 200...299:
            return nil
        case 400:
            let message = body.isEmpty
                ? "Claude Code didn't accept the request."
                : String(body.prefix(2_048))
            return .badRequest(message: message)
        case 401:
            return .unauthorized
        case 404:
            return .routineNotFound
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 402, 403, 405...428, 430...499:
            let message = body.isEmpty
                ? "Claude Code didn't accept the request."
                : String(body.prefix(2_048))
            return .invalidRequest(status: status, message: message)
        case 500...599:
            return .serverError(status: status)
        default:
            return .invalidRequest(status: status, message: String(body.prefix(2_048)))
        }
    }

    /// Wrap a `URLError` into a transport-level error. Doesn't distinguish
    /// timeout vs DNS vs offline — the UI presentation is the same.
    static func transport(_ urlError: URLError) -> ClaudeCodeRoutineError {
        .transport(message: urlError.localizedDescription)
    }
}
