import Foundation

/// Pure validation: given the current `AppSettings` values, decide whether
/// the Claude Code post-Notion routine is ready to fire.
///
/// Three branches surfaced in the Settings UI and used by the pipeline:
/// `.disabled` (toggle off), `.misconfigured` (toggle on, something
/// missing/malformed), `.ready` (toggle on + endpoint URL well-formed +
/// token present). The pipeline coordinator uses the same result to
/// decide whether to wire the post-Notion hook at all.
enum ClaudeCodeConfigStatus: Equatable, Sendable {
    case disabled
    case misconfigured(reason: String)
    case ready(ClaudeCodeRoutineConfig)
}

/// Pure functions over `AppSettings`. No I/O, no observation — the caller
/// passes in the values explicitly so this is trivially testable.
enum ClaudeCodeValidation {

    /// Inspect a `(enabled, endpoint, token, extraText)` quad and produce
    /// the validation status. Whitespace-only token and endpoint count as
    /// empty.
    static func validate(
        enabled: Bool,
        endpoint: String,
        token: String?,
        extraText: String
    ) -> ClaudeCodeConfigStatus {
        guard enabled else { return .disabled }

        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            return .misconfigured(reason: "Claude Code endpoint is missing.")
        }
        guard let url = URL(string: trimmedEndpoint),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = url.host, !host.isEmpty
        else {
            return .misconfigured(reason: "Claude Code endpoint isn't a valid URL.")
        }

        let trimmedToken = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return .misconfigured(reason: "Claude Code API token is missing.")
        }

        // extraText is allowed to be empty (PRD §4.4); pass it through verbatim.
        return .ready(ClaudeCodeRoutineConfig(
            endpoint: url,
            token: trimmedToken,
            extraText: extraText
        ))
    }

    /// Convenience that reads directly from `AppSettings`. Marked
    /// `@MainActor` because `AppSettings` is main-actor-isolated.
    @MainActor
    static func validate(_ settings: AppSettings) -> ClaudeCodeConfigStatus {
        validate(
            enabled: settings.claudeCodeNotesEnabled,
            endpoint: settings.claudeCodeEndpoint,
            token: settings.claudeCodeToken,
            extraText: settings.claudeCodeExtraText
        )
    }
}
