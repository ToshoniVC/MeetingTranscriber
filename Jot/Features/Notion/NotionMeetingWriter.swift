import Foundation

/// Result of a successful create-page call.
struct NotionPageResult: Equatable, Sendable {
    /// Notion-assigned page ID (the UUID under the URL).
    let pageId: String

    /// Browser-friendly URL to open the new page.
    let url: URL
}

/// Public surface the Pipeline depends on. Concrete impl: `NotionClient`.
/// Tests substitute a fake to drive the pipeline's failure / success paths
/// without standing up a `URLProtocol` mock.
protocol NotionMeetingWriter: Sendable {

    /// Create one new page in the configured Notion database with the
    /// three required toggle sections (Meeting Notes empty, Meeting
    /// Transcript filled, Additional Context filled).
    ///
    /// May issue more than one HTTP call internally — a large transcript
    /// triggers follow-up `PATCH /v1/blocks/{id}/children` calls — but the
    /// returned `NotionPageResult` only describes the new page itself.
    func createMeetingPage(
        config: NotionConfig,
        meetingName: String,
        transcript: String,
        additionalContext: String
    ) async throws -> NotionPageResult

    /// Validate connectivity + database access without creating a page.
    /// Used by the Settings "Test connection" button. Returns the
    /// `NotionDatabaseInfo` so the UI can show the database's name.
    func describeDatabase(config: NotionConfig) async throws -> NotionDatabaseInfo
}

/// Summary of a Notion database — only the fields Jot actually needs.
struct NotionDatabaseInfo: Equatable, Sendable {
    /// Plain-text concatenation of the database's title rich-text runs.
    /// May be empty if the database has an empty title.
    let title: String

    /// Name of the database's title property — needed to address it in
    /// create-page calls. Notion guarantees exactly one title property
    /// per database; we surface its display name (e.g., "Name").
    let titlePropertyName: String
}
