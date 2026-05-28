import Foundation

/// `Encodable` body for the Claude Code routine fire call. PRD §4.4 fixes
/// the shape at a single JSON object with a `text` field — kept as an
/// explicit struct so the wire contract is self-documenting and the tests
/// can assert against a typed Encodable.
struct ClaudeCodeRoutineRequest: Encodable, Equatable {

    /// Optional turn appended to the routine session. May be empty —
    /// PRD §4.4 explicitly allows that.
    let text: String
}
