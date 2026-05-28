import Foundation

/// One row in the Audit Log tab (PRD §3.2 Tab 2). Codable so the
/// `AuditLogStore` can persist the whole log to disk and survive relaunches.
///
/// **Schema v2** (Phase G): adds `contextAttached` and `organizationName`.
/// Both are Optional so v1 entries on disk decode cleanly without a
/// migration step — `init(from:)` defaults `schemaVersion` to 1 when
/// absent, and the auto-synthesized decode treats missing Optional fields
/// as nil. New entries always write `schemaVersion: 2`.
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

    /// On-disk schema version. Bumped to 2 in Phase G. New entries default
    /// to the current value; legacy rows decode as 1 (treated as
    /// "pre-Add-Context").
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
        schemaVersion: Int = 2
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
        self.schemaVersion = schemaVersion
    }

    /// Custom decoder so legacy v1 JSON (which has no `schemaVersion`,
    /// `contextAttached`, or `organizationName` keys) loads cleanly.
    /// Auto-synthesized decode would crash on the missing required
    /// `schemaVersion` field; this hand-rolled init defaults it to 1.
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
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}
