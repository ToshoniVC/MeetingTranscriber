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
        organizationName: String? = nil,
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
            organizationName: organizationName,
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
        organizationName: String?? = nil,
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
        if let organizationName {
            current.snapshot.organizationName = organizationName
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
    ///
    /// Legacy single-file path. The v0.4.1 batching path (introduced
    /// alongside Audio Hijack's split-file recording) uses `peek` instead so
    /// the snapshot survives across all parts of one meeting; `clearPending`
    /// fires once when the batch is flushed.
    func consume(forFileCreatedAt creationDate: Date, now: Date = Date()) -> MeetingContextSnapshot? {
        guard let snapshot = peek(forFileCreatedAt: creationDate, now: now) else {
            return nil
        }
        pending = nil
        return snapshot
    }

    /// Non-mutating window check — returns the active snapshot if
    /// `creationDate` falls inside `[startedAt - slop, (stoppedAt ?? now) + slop]`,
    /// otherwise nil. Used by the batch accumulator to identify split parts
    /// without burning the snapshot on the first one.
    ///
    /// The "expired" branch (`now - startedAt > maxAge`) still clears
    /// `pending` because a stale window is no longer valid for anything.
    func peek(forFileCreatedAt creationDate: Date, now: Date = Date()) -> MeetingContextSnapshot? {
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
        return entry.snapshot
    }

    /// Clear the pending entry. Called by the batch accumulator after it
    /// emits a closed batch — the snapshot has done its job at that point.
    /// Idempotent.
    func clearPending() {
        pending = nil
    }

    /// Non-consuming peek at the currently-pending recording's `startedAt`.
    /// Returns nil when no recording is in flight, or when the pending
    /// entry has aged past `maxAge` (in which case it's cleared, matching
    /// `peek(forFileCreatedAt:)`'s stale-window behavior).
    ///
    /// Used by `ProcessingPipeline.relocateMissingFile` to anchor a
    /// parent-directory scan when the URL the watcher emitted no longer
    /// exists — Audio Hijack can rename the recording after stop based
    /// on its Recorder block filename template, leaving us looking at a
    /// stale path. With this anchor we can find the actual file by
    /// creation-date proximity instead of failing with "file not found".
    func pendingStartedAt(now: Date = Date()) -> Date? {
        guard let entry = pending else { return nil }
        if now.timeIntervalSince(entry.startedAt) > Self.maxAge {
            pending = nil
            return nil
        }
        return entry.startedAt
    }

    /// Clear any pending entry without consuming it. Used by callers that
    /// know the snapshot is no longer wanted (e.g., user-cancelled flows)
    /// and by tests.
    func reset() {
        pending = nil
    }

    /// Sanitize a user-typed meeting name into a filename component.
    /// Removes characters the filesystem can't represent (`/`, `\0`) plus
    /// a few (`:`, control chars) the Finder can't display sensibly, trims
    /// dots and whitespace, and caps the length. Returns nil if nothing
    /// usable remains.
    ///
    /// `nonisolated` so the pipeline actor can call it without a hop —
    /// pure function over the input, no shared state. Inherited from the
    /// now-removed `MeetingNameStore`.
    nonisolated static func sanitizedFilenameComponent(_ raw: String) -> String? {
        // Replace forbidden chars with a hyphen. `/` and `\0` are the only
        // ones POSIX strictly forbids; `:` is forbidden by HFS+ legacy paths
        // and shows up as `/` in the Finder. The rest are characters that
        // look fine in a UI but break shell tooling or look odd in a file
        // browser.
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                cleaned.append("-")
            } else if scalar == "/" || scalar == ":" || scalar == "\\" {
                cleaned.append("-")
            } else {
                cleaned.append(Character(scalar))
            }
        }
        while cleaned.contains("--") {
            cleaned = cleaned.replacingOccurrences(of: "--", with: "-")
        }
        let trimmed = cleaned.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        )
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > 200 {
            return String(trimmed.prefix(200))
        }
        return trimmed
    }
}
