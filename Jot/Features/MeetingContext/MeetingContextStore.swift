import Foundation
import Observation

/// In-memory record of the most-recent Jot-initiated recording — the
/// successor to `MeetingNameStore` that holds the full `MeetingContextSnapshot`
/// (name + organization + meeting-specific context + compiled prompt) for
/// the *currently active* recording.
///
/// The window-matching guard (`consume(forFileCreatedAt:now:)`) is identical
/// to `MeetingNameStore`'s — we must never apply a snapshot unless we can
/// prove (within a couple of seconds of slop) that the audio file came from
/// the session Jot just kicked off.
///
/// State only lives in memory. A relaunch or crash forfeits any pending
/// snapshot, same trade-off as `MeetingNameStore` — see that type for the
/// reasoning.
///
/// Phase D rewires `HotkeyCoordinator` and the meeting-start prompter to
/// drive this store instead of `MeetingNameStore`. Phase F's pipeline
/// consumes from here when a file lands.
@MainActor
@Observable
final class MeetingContextStore {

    /// Lifecycle bounds for `consume` matching, mirroring `MeetingNameStore`.
    private static let timestampSlop: TimeInterval = 2
    private static let maxAge: TimeInterval = 4 * 60 * 60

    struct Pending: Equatable {
        var snapshot: MeetingContextSnapshot
        let startedAt: Date
        var stoppedAt: Date?
    }

    private(set) var pending: Pending?

    /// Begin tracking a new recording. Trimmed-empty `meetingName` clears
    /// the pending slot — there's no file rename to do for a nameless
    /// recording, and a stale pending would mis-attribute the next file.
    func recordStarted(
        meetingName: String,
        organizationId: UUID? = nil,
        meetingSpecificContext: String? = nil,
        resolvedCompiledContext: String = "",
        at date: Date = Date()
    ) {
        let trimmedName = meetingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            pending = nil
            return
        }
        let trimmedContext = meetingSpecificContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = MeetingContextSnapshot(
            meetingName: trimmedName,
            organizationId: organizationId,
            meetingSpecificContext: trimmedContext?.isEmpty == false ? trimmedContext : nil,
            resolvedCompiledContext: resolvedCompiledContext,
            lastEditedAt: date
        )
        pending = Pending(snapshot: snapshot, startedAt: date, stoppedAt: nil)
    }

    /// Mark the current recording as stopped. No-op if no pending entry.
    func recordStopped(at date: Date = Date()) {
        guard var current = pending else { return }
        current.stoppedAt = date
        pending = current
    }

    /// Update the pending snapshot mid-recording (Phase E: in-recording
    /// editor). No-op if there's no pending entry. Bumps `lastEditedAt`.
    /// The caller is responsible for recompiling `resolvedCompiledContext`
    /// when the inputs change.
    func update(
        meetingName: String? = nil,
        organizationId: UUID?? = nil,
        meetingSpecificContext: String?? = nil,
        resolvedCompiledContext: String? = nil,
        at date: Date = Date()
    ) {
        guard var current = pending else { return }
        if let meetingName {
            current.snapshot.meetingName = meetingName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let organizationId {
            current.snapshot.organizationId = organizationId
        }
        if let meetingSpecificContext {
            let trimmed = meetingSpecificContext?.trimmingCharacters(in: .whitespacesAndNewlines)
            current.snapshot.meetingSpecificContext = (trimmed?.isEmpty == false) ? trimmed : nil
        }
        if let resolvedCompiledContext {
            current.snapshot.resolvedCompiledContext = resolvedCompiledContext
        }
        current.snapshot.lastEditedAt = date
        pending = current
    }

    /// If `creationDate` falls within the active recording window, return
    /// the snapshot and clear the pending slot. Otherwise return nil and
    /// leave pending intact — a later file may still match.
    func consume(forFileCreatedAt creationDate: Date, now: Date = Date()) -> MeetingContextSnapshot? {
        guard let entry = pending else { return nil }

        if now.timeIntervalSince(entry.startedAt) > Self.maxAge {
            pending = nil
            return nil
        }

        let lowerBound = entry.startedAt.addingTimeInterval(-Self.timestampSlop)
        let upperBound = (entry.stoppedAt ?? now).addingTimeInterval(Self.timestampSlop)
        guard creationDate >= lowerBound, creationDate <= upperBound else {
            return nil
        }

        pending = nil
        return entry.snapshot
    }

    /// Clear any pending entry without consuming it. Used by callers that
    /// know the snapshot is no longer wanted (e.g., user-cancelled flows)
    /// and by tests.
    func reset() {
        pending = nil
    }
}
