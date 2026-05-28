import Testing
import Foundation
@testable import Jot

/// Tests for `MeetingContextStore` — the successor to `MeetingNameStore`
/// that holds the full meeting context snapshot in memory across a
/// recording's lifecycle.
@MainActor
struct MeetingContextStoreTests {

    // MARK: - recordStarted

    @Test
    func recordStarted_setsPending() {
        let store = MeetingContextStore()
        let orgID = UUID()
        store.recordStarted(
            meetingName: "Sync",
            organizationId: orgID,
            meetingSpecificContext: "Notes",
            resolvedCompiledContext: "compiled"
        )
        #expect(store.pending?.snapshot.meetingName == "Sync")
        #expect(store.pending?.snapshot.organizationId == orgID)
        #expect(store.pending?.snapshot.meetingSpecificContext == "Notes")
        #expect(store.pending?.snapshot.resolvedCompiledContext == "compiled")
    }

    @Test
    func recordStarted_trimsName() {
        let store = MeetingContextStore()
        store.recordStarted(meetingName: "  Sync  ")
        #expect(store.pending?.snapshot.meetingName == "Sync")
    }

    @Test
    func recordStarted_emptyName_clearsPending() {
        let store = MeetingContextStore()
        store.recordStarted(meetingName: "Sync")
        store.recordStarted(meetingName: "   ")
        #expect(store.pending == nil)
    }

    @Test
    func recordStarted_emptyMeetingContext_storesNil() {
        let store = MeetingContextStore()
        store.recordStarted(meetingName: "Sync", meetingSpecificContext: "   ")
        #expect(store.pending?.snapshot.meetingSpecificContext == nil)
    }

    // MARK: - update

    @Test
    func update_changesFieldsAndBumpsLastEditedAt() {
        let store = MeetingContextStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordStarted(meetingName: "Old", at: start)

        let later = start.addingTimeInterval(60)
        let newOrg = UUID()
        store.update(
            meetingName: "New",
            organizationId: .some(newOrg),
            meetingSpecificContext: .some("Updated"),
            resolvedCompiledContext: "new-compiled",
            at: later
        )

        #expect(store.pending?.snapshot.meetingName == "New")
        #expect(store.pending?.snapshot.organizationId == newOrg)
        #expect(store.pending?.snapshot.meetingSpecificContext == "Updated")
        #expect(store.pending?.snapshot.resolvedCompiledContext == "new-compiled")
        #expect(store.pending?.snapshot.lastEditedAt == later)
    }

    @Test
    func update_clearOrgWithExplicitNil() {
        let store = MeetingContextStore()
        store.recordStarted(meetingName: "Sync", organizationId: UUID())
        store.update(organizationId: .some(nil))
        #expect(store.pending?.snapshot.organizationId == nil)
    }

    @Test
    func update_onlyMutatesProvidedFields() {
        let store = MeetingContextStore()
        let orgID = UUID()
        store.recordStarted(meetingName: "Sync", organizationId: orgID, meetingSpecificContext: "Notes")
        store.update(meetingName: "Renamed")
        #expect(store.pending?.snapshot.meetingName == "Renamed")
        #expect(store.pending?.snapshot.organizationId == orgID)
        #expect(store.pending?.snapshot.meetingSpecificContext == "Notes")
    }

    @Test
    func update_noPending_isNoOp() {
        let store = MeetingContextStore()
        store.update(meetingName: "Sync")
        #expect(store.pending == nil)
    }

    // MARK: - consume window

    @Test
    func consume_withinRecordingWindow_returnsSnapshotAndClears() {
        let store = MeetingContextStore()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordStarted(meetingName: "Sync", at: started)

        let stopped = started.addingTimeInterval(30)
        store.recordStopped(at: stopped)

        let fileCreated = started.addingTimeInterval(15)
        let snap = store.consume(forFileCreatedAt: fileCreated, now: stopped.addingTimeInterval(1))
        #expect(snap?.meetingName == "Sync")
        #expect(store.pending == nil)
    }

    @Test
    func consume_beforeWindow_returnsNilAndKeepsPending() {
        let store = MeetingContextStore()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordStarted(meetingName: "Sync", at: started)

        let tooEarly = started.addingTimeInterval(-30)
        let snap = store.consume(forFileCreatedAt: tooEarly, now: started.addingTimeInterval(10))
        #expect(snap == nil)
        #expect(store.pending != nil)
    }

    @Test
    func consume_pastMaxAge_clearsPendingAndReturnsNil() {
        let store = MeetingContextStore()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordStarted(meetingName: "Sync", at: started)

        let fiveHoursLater = started.addingTimeInterval(5 * 60 * 60)
        let snap = store.consume(forFileCreatedAt: started, now: fiveHoursLater)
        #expect(snap == nil)
        #expect(store.pending == nil)
    }

    @Test
    func update_afterConsume_isNoOp() {
        let store = MeetingContextStore()
        store.recordStarted(meetingName: "Sync")
        _ = store.consume(forFileCreatedAt: Date())
        store.update(meetingName: "Changed")
        #expect(store.pending == nil)
    }

    // MARK: - reset

    @Test
    func reset_clearsPending() {
        let store = MeetingContextStore()
        store.recordStarted(meetingName: "Sync")
        store.reset()
        #expect(store.pending == nil)
    }

    // MARK: - pendingStartedAt (v0.4.7 AH-rename anchor)

    @Test
    func pendingStartedAt_returnsNilWhenIdle() {
        let store = MeetingContextStore()
        #expect(store.pendingStartedAt() == nil)
    }

    @Test
    func pendingStartedAt_returnsStartTimeWhileRecording() {
        let store = MeetingContextStore()
        let startTime = Date()
        store.recordStarted(meetingName: "Demo", at: startTime)
        #expect(store.pendingStartedAt() == startTime)
    }

    @Test
    func pendingStartedAt_doesNotConsumePending() {
        // Peek must leave `pending` intact so the legacy single-file
        // consume path still works after the pipeline relocates a file.
        let store = MeetingContextStore()
        let startTime = Date()
        store.recordStarted(meetingName: "Demo", at: startTime)
        _ = store.pendingStartedAt()
        _ = store.pendingStartedAt()
        #expect(store.pending != nil)
    }

    @Test
    func pendingStartedAt_clearsAndReturnsNilWhenExpired() {
        // Same stale-window rule as `peek` — a pending entry older than
        // `maxAge` is cleared and returns nil.
        let store = MeetingContextStore()
        let longAgo = Date(timeIntervalSinceNow: -5 * 60 * 60) // 5h > maxAge (4h)
        store.recordStarted(meetingName: "Demo", at: longAgo)
        #expect(store.pendingStartedAt() == nil)
        #expect(store.pending == nil)
    }
}
