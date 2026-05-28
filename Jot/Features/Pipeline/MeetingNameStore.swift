import Foundation
import Observation

/// In-memory record of the most recent Jot-initiated recording. Used by the
/// pipeline to decide whether to rename a freshly-arrived audio file to the
/// meeting name the user typed at the start prompt.
///
/// The window-matching guard (see `consume(forFileCreatedAt:now:)`) is the
/// reason this store exists at all: Audio Hijack drops timestamp-named files
/// into the Watch Folder whether *we* triggered the recording or the user
/// did it themselves from AH's UI. We must never rename a file unless we can
/// prove (within a couple of seconds of slop) that it came from a session
/// Jot kicked off.
///
/// State only lives in memory — pending entries are deliberately not
/// persisted. A relaunch or crash means we forfeit any rename owed to a
/// recording in flight at the time; that's the right trade-off vs. risking
/// a wrong rename on the user's next manual AH recording.
@MainActor
@Observable
final class MeetingNameStore {

    /// Bounds for the file-timestamp check. See type docs above for why.
    private static let timestampSlop: TimeInterval = 2

    /// Entries older than this are treated as stale and never match. Bounds
    /// the worst case where Jot started a recording, then crashed or quit
    /// before seeing the stop — without this, a stale `startedAt` could
    /// match a totally unrelated file the user produces hours later.
    private static let maxAge: TimeInterval = 4 * 60 * 60

    struct Pending: Equatable {
        let meetingName: String
        let startedAt: Date
        var stoppedAt: Date?
    }

    private(set) var pending: Pending?

    /// Begin tracking a new recording. Trimmed-empty names clear the pending
    /// slot — there's no rename to do for a nameless recording, and leaving
    /// a stale pending around would mis-attribute the next file.
    func recordStarted(name: String, at date: Date = Date()) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pending = nil
            return
        }
        pending = Pending(meetingName: trimmed, startedAt: date, stoppedAt: nil)
    }

    /// Mark the current recording as stopped. No-op if no pending entry —
    /// happens when the user stopped a recording Jot didn't start, or after
    /// we've already consumed the rename for a previous start.
    func recordStopped(at date: Date = Date()) {
        guard var current = pending else { return }
        current.stoppedAt = date
        pending = current
    }

    /// If the file's creation date falls within the active recording window,
    /// return the meeting name and clear the pending slot. Otherwise return
    /// nil and leave the pending slot intact — a later file may still match.
    ///
    /// - Parameters:
    ///   - creationDate: the file's inode creation timestamp (from
    ///     `URLResourceKey.creationDateKey`). Approximates when AH opened
    ///     the file for writing — i.e., when recording actually began.
    ///   - now: passed in for testability. Production callers use `Date()`.
    func consume(forFileCreatedAt creationDate: Date, now: Date = Date()) -> String? {
        guard let entry = pending else { return nil }

        // Stale recording → never match. Clear it out so it can't pollute a
        // later check either.
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
        return entry.meetingName
    }

    /// Clear any pending entry without consuming it. Used by callers that
    /// know the rename is no longer wanted (e.g., user-cancelled flows that
    /// somehow reach a stop after partial state) and by tests.
    func reset() {
        pending = nil
    }

    /// Sanitize a user-typed meeting name into a filename component. Removes
    /// characters the filesystem can't represent (`/`, `\0`) plus a few
    /// (`:`, control chars) the Finder can't display sensibly, trims dots
    /// and whitespace, and caps the length. Returns nil if nothing usable
    /// remains.
    ///
    /// `nonisolated` so the pipeline actor can call it without a hop —
    /// pure function over the input, no shared state.
    nonisolated static func sanitizedFilenameComponent(_ raw: String) -> String? {
        // Replace forbidden chars with a hyphen. `/` and `\0` are the only
        // ones POSIX strictly forbids; `:` is forbidden by HFS+ legacy paths
        // and shows up as `/` in the Finder. The rest of these are characters
        // that look fine in a UI but break shell tooling or look odd in a
        // file browser.
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
        // Collapse runs of hyphens introduced by sanitization so we don't
        // end up with names like "a---b" from "a/:\\b".
        while cleaned.contains("--") {
            cleaned = cleaned.replacingOccurrences(of: "--", with: "-")
        }
        // Trim leading/trailing dots (which produce hidden files / odd
        // resolution behavior) and whitespace.
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !trimmed.isEmpty else { return nil }
        // Cap at 200 chars to leave room for a collision suffix + extension
        // inside macOS's 255-byte filename limit.
        if trimmed.count > 200 {
            return String(trimmed.prefix(200))
        }
        return trimmed
    }
}
