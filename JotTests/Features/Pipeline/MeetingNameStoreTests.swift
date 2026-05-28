import Testing
import Foundation
@testable import Jot

/// Pure-logic tests for `MeetingNameStore`. The store is `@MainActor` because
/// it lives next to the menu-bar UI in production, so the suite is too.
@MainActor
struct MeetingNameStoreTests {

    // MARK: - recordStarted

    @Test
    func recordStarted_withName_setsPending() {
        let store = MeetingNameStore()
        let now = Date()
        store.recordStarted(name: "Standup", at: now)
        #expect(store.pending?.meetingName == "Standup")
        #expect(store.pending?.startedAt == now)
        #expect(store.pending?.stoppedAt == nil)
    }

    @Test
    func recordStarted_trimsWhitespace() {
        let store = MeetingNameStore()
        store.recordStarted(name: "  Standup  ", at: Date())
        #expect(store.pending?.meetingName == "Standup")
    }

    @Test
    func recordStarted_withEmptyName_clearsPending() {
        let store = MeetingNameStore()
        store.recordStarted(name: "OldMeeting", at: Date())
        store.recordStarted(name: "", at: Date())
        #expect(store.pending == nil)
    }

    @Test
    func recordStarted_withWhitespaceOnlyName_clearsPending() {
        let store = MeetingNameStore()
        store.recordStarted(name: "OldMeeting", at: Date())
        store.recordStarted(name: "   \n  ", at: Date())
        #expect(store.pending == nil)
    }

    @Test
    func recordStarted_replacesPreviousPending() {
        let store = MeetingNameStore()
        store.recordStarted(name: "First", at: Date(timeIntervalSinceReferenceDate: 0))
        store.recordStarted(name: "Second", at: Date(timeIntervalSinceReferenceDate: 100))
        #expect(store.pending?.meetingName == "Second")
        #expect(store.pending?.startedAt == Date(timeIntervalSinceReferenceDate: 100))
    }

    // MARK: - recordStopped

    @Test
    func recordStopped_setsStoppedDate() {
        let store = MeetingNameStore()
        let start = Date()
        let stop = start.addingTimeInterval(60)
        store.recordStarted(name: "Standup", at: start)
        store.recordStopped(at: stop)
        #expect(store.pending?.stoppedAt == stop)
    }

    @Test
    func recordStopped_withoutPending_isNoOp() {
        let store = MeetingNameStore()
        store.recordStopped(at: Date())
        #expect(store.pending == nil)
    }

    // MARK: - consume — happy path

    @Test
    func consume_fileCreatedDuringRecording_returnsName() {
        let store = MeetingNameStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let stop = start.addingTimeInterval(60)
        store.recordStarted(name: "Standup", at: start)
        store.recordStopped(at: stop)

        let inMiddle = start.addingTimeInterval(30)
        let result = store.consume(forFileCreatedAt: inMiddle, now: stop.addingTimeInterval(5))
        #expect(result == "Standup")
        // Pending was consumed.
        #expect(store.pending == nil)
    }

    @Test
    func consume_fileCreatedAtExactStart_returnsName() {
        let store = MeetingNameStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.recordStarted(name: "Standup", at: start)
        store.recordStopped(at: start.addingTimeInterval(60))

        let result = store.consume(forFileCreatedAt: start, now: start.addingTimeInterval(70))
        #expect(result == "Standup")
    }

    @Test
    func consume_withinSlopBeforeStart_returnsName() {
        // The slop allows up to 2 s of drift on either side.
        let store = MeetingNameStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.recordStarted(name: "Standup", at: start)
        store.recordStopped(at: start.addingTimeInterval(60))

        let oneSecondBefore = start.addingTimeInterval(-1)
        let result = store.consume(forFileCreatedAt: oneSecondBefore, now: start.addingTimeInterval(65))
        #expect(result == "Standup")
    }

    @Test
    func consume_withinSlopAfterStop_returnsName() {
        let store = MeetingNameStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let stop = start.addingTimeInterval(60)
        store.recordStarted(name: "Standup", at: start)
        store.recordStopped(at: stop)

        let oneSecondAfter = stop.addingTimeInterval(1)
        let result = store.consume(forFileCreatedAt: oneSecondAfter, now: stop.addingTimeInterval(5))
        #expect(result == "Standup")
    }

    // MARK: - consume — misses

    @Test
    func consume_fileBeforeStartByMoreThanSlop_returnsNil() {
        let store = MeetingNameStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.recordStarted(name: "Standup", at: start)
        store.recordStopped(at: start.addingTimeInterval(60))

        let tooEarly = start.addingTimeInterval(-3)
        let result = store.consume(forFileCreatedAt: tooEarly, now: start.addingTimeInterval(65))
        #expect(result == nil)
        // Pending preserved — a later, in-window file may still match.
        #expect(store.pending != nil)
    }

    @Test
    func consume_fileAfterStopByMoreThanSlop_returnsNil() {
        let store = MeetingNameStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let stop = start.addingTimeInterval(60)
        store.recordStarted(name: "Standup", at: start)
        store.recordStopped(at: stop)

        let tooLate = stop.addingTimeInterval(3)
        let result = store.consume(forFileCreatedAt: tooLate, now: stop.addingTimeInterval(10))
        #expect(result == nil)
        #expect(store.pending != nil)
    }

    @Test
    func consume_withoutPending_returnsNil() {
        let store = MeetingNameStore()
        let result = store.consume(forFileCreatedAt: Date(), now: Date())
        #expect(result == nil)
    }

    // MARK: - consume — open window (stop never observed)

    @Test
    func consume_openWindow_recentFile_returnsName() {
        // User started via Jot, then stopped via AH directly (Jot never saw
        // the stop). The window remains open up to `now + slop`.
        let store = MeetingNameStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.recordStarted(name: "Standup", at: start)

        let fileCreated = start.addingTimeInterval(45)
        let now = start.addingTimeInterval(90)
        let result = store.consume(forFileCreatedAt: fileCreated, now: now)
        #expect(result == "Standup")
    }

    @Test
    func consume_openWindow_fileInFutureBeyondSlop_returnsNil() {
        // Pathological: file's creation date is in the future relative to
        // `now`. Skip — something's wrong with the clock or this isn't our
        // file.
        let store = MeetingNameStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.recordStarted(name: "Standup", at: start)

        let now = start.addingTimeInterval(30)
        let fileInFuture = now.addingTimeInterval(10)
        let result = store.consume(forFileCreatedAt: fileInFuture, now: now)
        #expect(result == nil)
    }

    // MARK: - consume — staleness

    @Test
    func consume_pendingOlderThan4Hours_returnsNil() {
        let store = MeetingNameStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.recordStarted(name: "Standup", at: start)

        // 4h + 1s after start, with the file ostensibly created during the
        // session. Stale guard wins → no rename.
        let now = start.addingTimeInterval(4 * 60 * 60 + 1)
        let result = store.consume(forFileCreatedAt: start.addingTimeInterval(30), now: now)
        #expect(result == nil)
        // Stale pending was cleared as a side effect.
        #expect(store.pending == nil)
    }

    @Test
    func consume_pendingJustUnder4Hours_stillMatches() {
        let store = MeetingNameStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.recordStarted(name: "Standup", at: start)
        store.recordStopped(at: start.addingTimeInterval(60))

        let now = start.addingTimeInterval(4 * 60 * 60 - 1)
        let result = store.consume(forFileCreatedAt: start.addingTimeInterval(30), now: now)
        #expect(result == "Standup")
    }

    // MARK: - reset

    @Test
    func reset_clearsPending() {
        let store = MeetingNameStore()
        store.recordStarted(name: "Standup", at: Date())
        store.reset()
        #expect(store.pending == nil)
    }

    // MARK: - sanitization

    @Test
    func sanitize_plainName_returnsAsIs() {
        #expect(MeetingNameStore.sanitizedFilenameComponent("Standup") == "Standup")
        #expect(MeetingNameStore.sanitizedFilenameComponent("Client Call 2026") == "Client Call 2026")
    }

    @Test
    func sanitize_replacesForbiddenChars() {
        #expect(MeetingNameStore.sanitizedFilenameComponent("a/b") == "a-b")
        #expect(MeetingNameStore.sanitizedFilenameComponent("a:b") == "a-b")
        #expect(MeetingNameStore.sanitizedFilenameComponent("a\\b") == "a-b")
    }

    @Test
    func sanitize_collapsesHyphenRuns() {
        // Multiple forbidden chars in a row should not produce "----".
        #expect(MeetingNameStore.sanitizedFilenameComponent("a/:\\b") == "a-b")
    }

    @Test
    func sanitize_stripsControlChars() {
        #expect(MeetingNameStore.sanitizedFilenameComponent("a\u{0007}b") == "a-b")
        #expect(MeetingNameStore.sanitizedFilenameComponent("a\nb") == "a-b")
    }

    @Test
    func sanitize_trimsLeadingTrailingDotsAndWhitespace() {
        #expect(MeetingNameStore.sanitizedFilenameComponent("...Standup...") == "Standup")
        #expect(MeetingNameStore.sanitizedFilenameComponent("  Standup  ") == "Standup")
        #expect(MeetingNameStore.sanitizedFilenameComponent(" .Standup. ") == "Standup")
    }

    @Test
    func sanitize_emptyAfterTrimming_returnsNil() {
        #expect(MeetingNameStore.sanitizedFilenameComponent("") == nil)
        #expect(MeetingNameStore.sanitizedFilenameComponent("   ") == nil)
        #expect(MeetingNameStore.sanitizedFilenameComponent("...") == nil)
        // "////" sanitizes to "-" → trimmed of nothing → "-" survives. The
        // user gets a single-hyphen filename. Not pretty but harmless.
        #expect(MeetingNameStore.sanitizedFilenameComponent("////") == "-")
    }

    @Test
    func sanitize_truncatesAt200Chars() {
        let long = String(repeating: "a", count: 250)
        let result = MeetingNameStore.sanitizedFilenameComponent(long)
        #expect(result?.count == 200)
    }

    @Test
    func sanitize_preservesNonASCII() {
        #expect(MeetingNameStore.sanitizedFilenameComponent("Réunion équipe") == "Réunion équipe")
        #expect(MeetingNameStore.sanitizedFilenameComponent("会议") == "会议")
    }
}
