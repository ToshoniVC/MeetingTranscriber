import Foundation

/// One row in the Audit Log tab (PRD §3.2 Tab 2). Codable so the
/// `AuditLogStore` can persist the whole log to disk and survive relaunches.
///
/// **Schema v7** (Notion-only retry): adds `meetingFolderPath` and starts
/// populating `retryMeetingName` / `retryCompiledContext` on *success*
/// rows too. Together they let the Audit Log replay just the Notion write
/// from the already-transcribed meeting on disk — no re-transcription —
/// when the page creation failed but transcription succeeded. All Optional
/// → legacy rows decode cleanly.
/// **Schema v6** (batch-aware retry): adds `batchPartPaths`,
/// `retryMeetingName`, `retryCompiledContext`, and `recordingStartedAt`
/// so a failed multi-part (Audio Hijack split) recording can be replayed
/// as one batch by the Retry button instead of re-running only the first
/// part as a lone single-file meeting. All Optional → legacy rows decode
/// cleanly.
/// **Schema v5** (Multiple Providers feature): adds
/// `transcriptionProvider`.
/// **Schema v4** (Claude Code Meeting Notes feature): adds
/// `claudeCodeStatus`.
/// **Schema v3** (Create Notion Meeting feature): adds `notionStatus`.
/// **Schema v2** (Add Context feature): adds `contextAttached` and
/// `organizationName`. All new fields are Optional so legacy entries
/// on disk decode cleanly without a separate migration step. The
/// hand-rolled `init(from:)` defaults `schemaVersion` to 1 when absent.
/// New entries always write the current schemaVersion.
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

    /// Display name of the transcription provider that produced this
    /// meeting's transcript (e.g., "OpenAI", "Groq"). Multi-provider
    /// batches that crossed providers via fallback show the chain
    /// joined with " + " (e.g., "OpenAI + Groq"). `nil` for non-
    /// pipeline rows, for v1–v4-schema rows decoded from older logs,
    /// and for pipelines wired to the legacy single-provider path
    /// (which doesn't know its own provider name). v0.4.5+.
    let transcriptionProvider: String?

    /// When this failure represents a multi-part (Audio Hijack split)
    /// recording, the part file paths in chronological order. Lets the
    /// Retry button replay the whole meeting as one batch instead of
    /// re-running only the first part as a lone single-file meeting.
    /// `nil` for single-file failures and every non-failure row. v0.7.1
    /// (schema v6).
    let batchPartPaths: [String]?

    /// Meeting name captured at batch time, replayed on retry. The live
    /// `MeetingContextStore` snapshot is cleared once a batch finishes
    /// (even on failure), so without this a batch retry would lose the
    /// user's meeting name and fall back to the raw filename. `nil`
    /// outside batch failures.
    let retryMeetingName: String?

    /// The compiled Whisper prompt captured at batch time, replayed
    /// verbatim on retry. `nil` when no context was attached or outside
    /// batch failures.
    let retryCompiledContext: String?

    /// The recording's start time, used as the relocation anchor when a
    /// part was renamed/moved by Audio Hijack between the original run
    /// and a retry. `nil` outside batch failures.
    let recordingStartedAt: Date?

    /// Filesystem path of the meeting's output folder (the per-meeting
    /// directory holding the `.txt` / `.json` transcripts). Stamped on
    /// success rows so a Notion-only retry can re-read the transcript from
    /// disk and replay the page creation without re-transcribing. `nil` on
    /// failure rows, on non-pipeline rows, and on v1–v6-schema rows. v7.
    let meetingFolderPath: String?

    /// On-disk schema version. Bumped from 6 → 7 for `meetingFolderPath`.
    /// New entries default to the current value; legacy rows decode as 1
    /// (pre-Add-Context) when the field is absent.
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
        transcriptionProvider: String? = nil,
        batchPartPaths: [String]? = nil,
        retryMeetingName: String? = nil,
        retryCompiledContext: String? = nil,
        recordingStartedAt: Date? = nil,
        meetingFolderPath: String? = nil,
        schemaVersion: Int = 7
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
        self.transcriptionProvider = transcriptionProvider
        self.batchPartPaths = batchPartPaths
        self.retryMeetingName = retryMeetingName
        self.retryCompiledContext = retryCompiledContext
        self.recordingStartedAt = recordingStartedAt
        self.meetingFolderPath = meetingFolderPath
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
        self.transcriptionProvider = try c.decodeIfPresent(String.self, forKey: .transcriptionProvider)
        self.batchPartPaths = try c.decodeIfPresent([String].self, forKey: .batchPartPaths)
        self.retryMeetingName = try c.decodeIfPresent(String.self, forKey: .retryMeetingName)
        self.retryCompiledContext = try c.decodeIfPresent(String.self, forKey: .retryCompiledContext)
        self.recordingStartedAt = try c.decodeIfPresent(Date.self, forKey: .recordingStartedAt)
        self.meetingFolderPath = try c.decodeIfPresent(String.self, forKey: .meetingFolderPath)
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
            transcriptionProvider: transcriptionProvider,
            batchPartPaths: batchPartPaths,
            retryMeetingName: retryMeetingName,
            retryCompiledContext: retryCompiledContext,
            recordingStartedAt: recordingStartedAt,
            meetingFolderPath: meetingFolderPath,
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
            transcriptionProvider: transcriptionProvider,
            batchPartPaths: batchPartPaths,
            retryMeetingName: retryMeetingName,
            retryCompiledContext: retryCompiledContext,
            recordingStartedAt: recordingStartedAt,
            meetingFolderPath: meetingFolderPath,
            schemaVersion: schemaVersion
        )
    }

    /// Return a copy of this entry with `retryable` replaced. Backs
    /// `AuditLogStore.markRetried(...)` — preserves every other field,
    /// including the batch-retry payload and schema version, so retiring
    /// a row never silently drops data.
    func withRetryable(_ retryable: Bool) -> AuditLogEntry {
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
            claudeCodeStatus: claudeCodeStatus,
            transcriptionProvider: transcriptionProvider,
            batchPartPaths: batchPartPaths,
            retryMeetingName: retryMeetingName,
            retryCompiledContext: retryCompiledContext,
            recordingStartedAt: recordingStartedAt,
            meetingFolderPath: meetingFolderPath,
            schemaVersion: schemaVersion
        )
    }
}
