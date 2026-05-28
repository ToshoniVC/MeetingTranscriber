import Foundation

/// Per-meeting outcome of the Claude Code routine fire, recorded on the
/// audit log entry that describes the meeting itself.
///
/// Lives in `Features/ClaudeCode/` because Claude Code owns the concept —
/// the AuditLog feature reads it but doesn't define it
/// (`coding-instructions.md` §2: feature A reaches into feature B only
/// via B's public surface).
///
/// Three states, matching PRD §4.4 + §5 (Phase E §4):
/// - `.skipped` — the toggle was off, settings were incomplete, or
///   Notion didn't succeed (no page to write into).
/// - `.fired` — the POST to the routine endpoint returned 2xx. The
///   routine itself runs server-side and Jot doesn't observe its
///   completion.
/// - `.failed` — the POST returned an error or transport failed.
enum ClaudeCodeRoutineStatus: Codable, Equatable, Sendable {

    case skipped(reason: SkipReason)
    case fired
    case failed(message: String)

    enum SkipReason: String, Codable, Equatable, Sendable {
        /// User left the toggle off.
        case disabled
        /// Toggle on but settings (endpoint/token) failed validation.
        case misconfigured
        /// Notion didn't reach the success step, so there's no page
        /// for the routine to write into.
        case notionNotReady
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind, reason, message
    }

    private enum Kind: String, Codable {
        case skipped, fired, failed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .skipped(let reason):
            try c.encode(Kind.skipped, forKey: .kind)
            try c.encode(reason, forKey: .reason)
        case .fired:
            try c.encode(Kind.fired, forKey: .kind)
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
        case .fired:
            self = .fired
        case .failed:
            let message = try c.decode(String.self, forKey: .message)
            self = .failed(message: message)
        }
    }
}
