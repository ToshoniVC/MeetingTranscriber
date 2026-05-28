import Foundation

/// Frozen per-meeting context — the inputs that produced the Whisper
/// `prompt` plus the compiled result itself. Persisted alongside the
/// transcript as `context.md` (Phase G) for auditability.
///
/// Shape per PRD §5.2 + plan Phase C.1. `schemaVersion` lets the on-disk
/// format evolve without losing prior meetings' artifacts.
struct MeetingContextSnapshot: Codable, Equatable, Sendable {

    var meetingName: String

    /// `nil` when the user explicitly picked "No Organization" — the sentinel
    /// is a UI affordance, not a stored record (see plan Phase B.3).
    var organizationId: UUID?

    /// Free-text the user typed in the meeting-start prompt or the
    /// in-recording editor. Trimmed when set; `nil` if empty.
    var meetingSpecificContext: String?

    /// The compiled string sent to the transcription endpoint. Computed
    /// from the org snapshot + meeting context at edit time; the pipeline
    /// may recompile defensively at file-arrival time (see plan Phase F.3).
    var resolvedCompiledContext: String

    /// When the snapshot was last mutated. Updated by every `update(...)`
    /// call on the store; not bumped by `recordStarted`.
    var lastEditedAt: Date

    var schemaVersion: Int

    init(
        meetingName: String,
        organizationId: UUID? = nil,
        meetingSpecificContext: String? = nil,
        resolvedCompiledContext: String = "",
        lastEditedAt: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.meetingName = meetingName
        self.organizationId = organizationId
        self.meetingSpecificContext = meetingSpecificContext
        self.resolvedCompiledContext = resolvedCompiledContext
        self.lastEditedAt = lastEditedAt
        self.schemaVersion = schemaVersion
    }
}
