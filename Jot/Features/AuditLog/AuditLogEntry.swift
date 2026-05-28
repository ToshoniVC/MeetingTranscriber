import Foundation

/// One row in the Audit Log tab (PRD §3.2 Tab 2). Codable so the
/// `AuditLogStore` can persist the whole log to disk and survive relaunches.
///
/// **Schema v4** (Claude Code Meeting Notes feature): adds
/// `claudeCodeStatus`.
/// **Schema v3** (Create Notion Meeting feature): adds `notionStatus`.
/// **Schema v2** (Add Context feature): adds `contextAttached` and
/// `organizationName`. All four new fields are Optional so legacy
/// entries on disk decode cleanly without a separate migration step.
/// The hand-rolled `init(from:)` defaults `schemaVersion` to 1 when
/// absent. New entries always write the current schemaVersion.
struct AuditLogEntry: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case info
        case success
        case failure
    }

    let id: UUID
    let timestamp: Date
    let kind: Kind
    let sourcePath: String
    let message: String
    let durationMs: Int?
    let retryable: Bool

    /// `true` / `false` / `nil` — set on pipeline success/failure entries
    /// that went through the transcription request. Nil on info rows and
    /// on v1-schema rows decoded from older logs.
    let contextAttached: Bool?

    /// Display name of the organization the meeting was filed under, if
    /// any. `nil` for "No Organization" meetings, for non-pipeline rows,
    /// and for v1-schema rows.
    let organizationName: String?

    /// Outcome of the Notion bridge for this meeting. `nil` for non-
    /// pipeline rows, for v1/v2-schema rows, and for pipelines that
    /// weren't aware of Notion at all (tests). Mutable through
    /// `AuditLogStore.updateNotionStatus(...)` so the row can flip from
    /// `.pending` to `.succeeded` / `.failed` once the async write
    /// completes.
    let notionStatus: NotionStatus?

    /// Outcome of the Claude Code routine fire for this meeting. `nil`
    /// for non-pipeline rows, for v1/v2/v3-schema rows, and for
    /// pipelines that weren't aware of Claude Code at all. Set in
    /// place via `AuditLogStore.updateClaudeCodeStatus(...)` once the
    /// post-Notion routine fire completes.
    let claudeCodeStatus: ClaudeCodeRoutineStatus?

    /// On-disk schema version. Bumped from 3 → 4 for `claudeCodeStatus`.
    /// New entries default to the current value; legacy rows decode as
    /// 1 (pre-Add-Context) when the field is absent.
    let schemaVersion: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        sourcePath: String,
        message: String,
        durationMs: Int? = nil,
        retryable: Bool = false,
        contextAttached: Bool? = nil,
        organizationName: String? = nil,
        notionStatus: NotionStatus? = nil,
        claudeCodeStatus: ClaudeCodeRoutineStatus? = nil,
        schemaVersion: Int = 4
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.sourcePath = sourcePath
        self.message = message
        self.durationMs = durationMs
        self.retryable = retryable
        self.contextAttached = contextAttached
        self.organizationName = organizationName
        self.notionStatus = notionStatus
        self.claudeCodeStatus = claudeCodeStatus
        self.schemaVersion = schemaVersion
    }

    /// Custom decoder so legacy v1/v2 JSON (which lack one or more of the
    /// fields below) loads cleanly. Missing Optional fields decode as nil;
    /// missing `schemaVersion` defaults to 1 (the original on-disk shape).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.sourcePath = try c.decode(String.self, forKey: .sourcePath)
        self.message = try c.decode(String.self, forKey: .message)
        self.durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        self.retryable = try c.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        self.contextAttached = try c.decodeIfPresent(Bool.self, forKey: .contextAttached)
        self.organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName)
        self.notionStatus = try c.decodeIfPresent(NotionStatus.self, forKey: .notionStatus)
        self.claudeCodeStatus = try c.decodeIfPresent(ClaudeCodeRoutineStatus.self, forKey: .claudeCodeStatus)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    /// Return a copy of this entry with `notionStatus` replaced. Used by
    /// `AuditLogStore.updateNotionStatus(...)` after the async Notion
    /// write completes (or fails). Other fields are immutable by design.
    func withNotionStatus(_ status: NotionStatus?) -> AuditLogEntry {
        AuditLogEntry(
            id: id,
            timestamp: timestamp,
            kind: kind,
            sourcePath: sourcePath,
            message: message,
            durationMs: durationMs,
            retryable: retryable,
            contextAttached: contextAttached,
            organizationName: organizationName,
            notionStatus: status,
            claudeCodeStatus: claudeCodeStatus,
            schemaVersion: schemaVersion
        )
    }

    /// Return a copy of this entry with `claudeCodeStatus` replaced.
    /// Used by `AuditLogStore.updateClaudeCodeStatus(...)` once the
    /// post-Notion routine fire completes.
    func withClaudeCodeStatus(_ status: ClaudeCodeRoutineStatus?) -> AuditLogEntry {
        AuditLogEntry(
            id: id,
            timestamp: timestamp,
            kind: kind,
            sourcePath: sourcePath,
            message: message,
            durationMs: durationMs,
            retryable: retryable,
            contextAttached: contextAttached,
            organizationName: organizationName,
            notionStatus: notionStatus,
            claudeCodeStatus: status,
            schemaVersion: schemaVersion
        )
    }
}
