import Foundation

/// One row in the Audit Log tab (PRD §3.2 Tab 2). Codable so the
/// `AuditLogStore` can persist the whole log to disk and survive relaunches.
struct AuditLogEntry: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case info
        case success
        case failure
    }

    /// Stable identity for SwiftUI lists and for the "mark as retried" call.
    let id: UUID

    /// When the event was logged (not when the underlying I/O started).
    let timestamp: Date

    let kind: Kind

    /// Absolute path of the file the event is about. Used by the Retry
    /// button to re-enqueue the same source.
    let sourcePath: String

    /// One-line user-facing description. Audit Log rows display this.
    let message: String

    /// Total elapsed time for the underlying operation, in milliseconds.
    /// Used in row subtitles ("transcribed in 12.4s"). `nil` for events
    /// where duration isn't meaningful (e.g., a startup info entry).
    let durationMs: Int?

    /// `true` iff this entry represents a failed pipeline run that the
    /// user can retry. The row shows a Retry button when `true`.
    /// Becomes `false` after retry succeeds or is explicitly dismissed.
    let retryable: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        sourcePath: String,
        message: String,
        durationMs: Int? = nil,
        retryable: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.sourcePath = sourcePath
        self.message = message
        self.durationMs = durationMs
        self.retryable = retryable
    }
}
