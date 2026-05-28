import Foundation

/// Per-meeting outcome of the Notion bridge, recorded on the audit log
/// entry that describes the meeting itself.
///
/// Lives in `Features/Notion/` because Notion owns the concept — the
/// AuditLog feature reads it but doesn't define it (`coding-instructions.md`
/// §2: feature A reaches into feature B only via B's public surface).
enum NotionStatus: Codable, Equatable, Sendable {

    /// User opted out (toggle off) or has a half-configured Notion
    /// setting that fails validation. No network call was made.
    case skipped(reason: SkipReason)

    /// A Notion write is in flight or has been scheduled. Written
    /// alongside the success audit entry; replaced with `.succeeded` /
    /// `.failed` when the task completes.
    case pending

    /// Page was created. `pageURL` is the browser-friendly link.
    case succeeded(pageURL: URL)

    /// Notion write failed. `message` is a one-line summary suitable for
    /// a tooltip / detail disclosure — typically
    /// `NotionError.userFacingMessage`.
    case failed(message: String)

    enum SkipReason: String, Codable, Equatable, Sendable {
        case disabled
        case misconfigured
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind, reason, pageURL, message
    }

    private enum Kind: String, Codable {
        case skipped, pending, succeeded, failed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .skipped(let reason):
            try c.encode(Kind.skipped, forKey: .kind)
            try c.encode(reason, forKey: .reason)
        case .pending:
            try c.encode(Kind.pending, forKey: .kind)
        case .succeeded(let pageURL):
            try c.encode(Kind.succeeded, forKey: .kind)
            try c.encode(pageURL, forKey: .pageURL)
        case .failed(let message):
            try c.encode(Kind.failed, forKey: .kind)
            try c.encode(message, forKey: .message)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .skipped:
            let reason = try c.decode(SkipReason.self, forKey: .reason)
            self = .skipped(reason: reason)
        case .pending:
            self = .pending
        case .succeeded:
            let url = try c.decode(URL.self, forKey: .pageURL)
            self = .succeeded(pageURL: url)
        case .failed:
            let message = try c.decode(String.self, forKey: .message)
            self = .failed(message: message)
        }
    }
}
