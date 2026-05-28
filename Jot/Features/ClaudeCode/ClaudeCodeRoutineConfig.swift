import Foundation

/// Non-persisted snapshot of everything the Claude Code routine fire
/// client needs for one request. Mirrors `NotionConfig` — captured at
/// pipeline-start time so a mid-pipeline settings change can't change
/// per-file behavior; the coordinator restarts the pipeline on any
/// observed change.
struct ClaudeCodeRoutineConfig: Sendable, Equatable {

    /// Fire endpoint URL, validated to have a scheme + host before
    /// reaching here. PRD §4.4 documents the canonical shape
    /// (`/v1/claude_code/routines/<trigger_id>/fire`) but the field is
    /// kept as a generic URL so future routing changes don't require a
    /// Jot release.
    let endpoint: URL

    /// Bearer token for the `Authorization` header. Never logged.
    let token: String

    /// Optional instruction text appended to the request body's `text`
    /// field. May be empty — PRD §4.4 explicitly allows that.
    let extraText: String

    /// Anthropic API version header, pinned to a known-good value per the
    /// same posture as `NotionConfig.defaultAPIVersion`. Bumped deliberately
    /// when we re-test.
    let apiVersion: String

    /// Anthropic beta-gate header for the routine fire surface. The
    /// API is in beta as of the PRD date — the value matches
    /// PRD §4.4 verbatim.
    let betaHeader: String

    init(
        endpoint: URL,
        token: String,
        extraText: String,
        apiVersion: String = ClaudeCodeRoutineConfig.defaultAPIVersion,
        betaHeader: String = ClaudeCodeRoutineConfig.defaultBetaHeader
    ) {
        self.endpoint = endpoint
        self.token = token
        self.extraText = extraText
        self.apiVersion = apiVersion
        self.betaHeader = betaHeader
    }

    /// Per PRD §4.4. Bump deliberately.
    static let defaultAPIVersion = "2023-06-01"

    /// Per PRD §4.4. Bump deliberately when Anthropic ships a non-beta
    /// surface or rotates the gate.
    static let defaultBetaHeader = "experimental-cc-routine-2026-04-01"
}
