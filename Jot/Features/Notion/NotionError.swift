import Foundation

/// Typed errors thrown by `NotionClient` calls. Designed so the Settings
/// "Test connection" UI and the Audit Log can present an actionable line
/// to the user without parsing strings.
enum NotionError: Error, Equatable, Sendable {

    /// 401 — the integration token was rejected.
    case unauthorized

    /// 404 — the database ID doesn't exist or the integration doesn't have
    /// access to it. The two cases look identical from Notion's API.
    case databaseNotFound

    /// 429 — Notion is rate-limiting us. We surface this without retrying;
    /// the user can re-run later. The `retryAfter` value is the server-
    /// supplied hint in seconds, or `nil` if the header was missing/parsed.
    case rateLimited(retryAfter: TimeInterval?)

    /// 4xx (other than the above). `message` is whatever the Notion error
    /// body said — useful for debugging schema mismatches.
    case invalidRequest(status: Int, message: String)

    /// 5xx — server problem. Not retried automatically (PRD §6: "Keep retry
    /// behavior minimal and explicit").
    case serverError(status: Int)

    /// Transport-level failure (DNS, connection refused, timeout).
    case transport(message: String)

    /// Couldn't decode Notion's response into the expected shape. Rare;
    /// usually means the API contract drifted.
    case decoding(message: String)

    /// The target database has no title property we could resolve. Either
    /// the database is malformed or Notion changed the schema shape.
    case missingTitleProperty

    /// Programmer error wrapped as a value (e.g., builder produced an
    /// invalid payload). Surfaces in the audit log so a regression
    /// doesn't fail silently.
    case internalInconsistency(String)

    /// User-facing one-line summary. Mirrors `TranscriptionError`.
    var userFacingMessage: String {
        switch self {
        case .unauthorized:
            return "Notion token was rejected. Check it in Settings."
        case .databaseNotFound:
            return "Notion database not found — confirm the ID and that the integration is shared with it."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Notion rate-limited the request (retry in \(Int(retryAfter))s)."
            }
            return "Notion rate-limited the request."
        case .invalidRequest(let status, let message):
            return "Notion rejected the request (HTTP \(status)): \(message)"
        case .serverError(let status):
            return "Notion returned HTTP \(status)."
        case .transport(let message):
            return "Network error reaching Notion: \(message)"
        case .decoding(let message):
            return "Couldn't read Notion's response: \(message)"
        case .missingTitleProperty:
            return "Notion database has no title property — Jot can't create pages in it."
        case .internalInconsistency(let detail):
            return "Internal error: \(detail)."
        }
    }
}

/// Pure mapping from HTTP status (+ best-effort body) to `NotionError`.
/// Exposed as a free enum so tests can hit it without standing up a client.
enum NotionErrorMapper {

    /// Returns nil for a successful (2xx) status, or the right
    /// `NotionError` case for everything else.
    static func error(
        forStatus status: Int,
        bodyHint body: String = "",
        retryAfter: TimeInterval? = nil
    ) -> NotionError? {
        switch status {
        case 200...299:
            return nil
        case 401:
            return .unauthorized
        case 404:
            return .databaseNotFound
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 400, 402, 403, 405...428, 430...499:
            let message = body.isEmpty
                ? "Notion didn't accept the request."
                : String(body.prefix(2_048))
            return .invalidRequest(status: status, message: message)
        case 500...599:
            return .serverError(status: status)
        default:
            return .invalidRequest(status: status, message: String(body.prefix(2_048)))
        }
    }

    /// Wrap a `URLError` into a transport-level `NotionError`. Doesn't
    /// distinguish timeout vs DNS vs offline because the UI presentation
    /// is the same — "couldn't talk to Notion."
    static func transport(_ urlError: URLError) -> NotionError {
        .transport(message: urlError.localizedDescription)
    }
}
