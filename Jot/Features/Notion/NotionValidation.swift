import Foundation

/// Pure validation: given the current `AppSettings`, decide whether the
/// Notion bridge is ready to attempt a write.
///
/// The Settings UI surfaces the three branches as distinct visual states:
/// `.disabled` (toggle off), `.misconfigured` (toggle on but something
/// missing/malformed), `.ready` (toggle on + token + databaseId well-formed).
/// The pipeline coordinator uses the same result to decide whether to wire
/// the post-success Notion callback at all.
enum NotionConfigStatus: Equatable, Sendable {
    case disabled
    case misconfigured(reason: String)
    case ready(NotionConfig)
}

/// Pure functions over `AppSettings`. No I/O, no observation tracking — the
/// caller passes in the current values explicitly so this is trivially
/// testable.
enum NotionValidation {

    /// Inspect a `(notionEnabled, notionToken, notionDatabaseId)` triple
    /// and produce the validation status. Treat whitespace-only token
    /// and databaseId as empty.
    static func validate(
        enabled: Bool,
        token: String?,
        databaseId: String
    ) -> NotionConfigStatus {
        guard enabled else { return .disabled }

        let trimmedToken = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return .misconfigured(reason: "Notion token is missing.")
        }

        let trimmedDb = databaseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDb.isEmpty else {
            return .misconfigured(reason: "Notion database ID is missing.")
        }

        guard let normalized = NotionConfig.normalize(databaseId: trimmedDb) else {
            return .misconfigured(reason: "Notion database ID isn't a valid 32-char ID.")
        }

        return .ready(NotionConfig(token: trimmedToken, databaseId: normalized))
    }

    /// Convenience that reads directly from `AppSettings`. Marked
    /// `@MainActor` because `AppSettings` is main-actor-isolated.
    @MainActor
    static func validate(_ settings: AppSettings) -> NotionConfigStatus {
        validate(
            enabled: settings.notionEnabled,
            token: settings.notionToken,
            databaseId: settings.notionDatabaseId
        )
    }
}
