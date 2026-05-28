import Testing
import Foundation
@testable import Jot

/// Integration test for the Phase E in-recording editing flow: start a
/// recording, mutate the snapshot the way the editor would, then consume
/// it as the pipeline would, and verify the consumed snapshot reflects
/// the edits.
///
/// The view itself isn't unit-tested (SwiftUI views are out of test scope
/// per `coding-instructions.md` §6); this test exercises the store API
/// the view drives.
@MainActor
struct CurrentMeetingEditingIntegrationTests {

    @Test
    func startThenEditThenConsume_returnsEditedSnapshot() {
        let store = MeetingContextStore()
        let acme = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)

        store.recordStarted(
            meetingName: "Old name",
            organizationId: nil,
            meetingSpecificContext: nil,
            resolvedCompiledContext: "",
            at: started
        )

        let editTime = started.addingTimeInterval(45)
        store.update(
            meetingName: "Updated name",
            organizationId: .some(acme),
            meetingSpecificContext: .some("Edited mid-recording"),
            resolvedCompiledContext: "compiled-after-edit",
            at: editTime
        )

        // File arrives a few seconds later, well inside the recording window
        // (between start and now — recording is still active, no stop).
        let fileCreated = started.addingTimeInterval(30)
        let snapshot = store.consume(
            forFileCreatedAt: fileCreated,
            now: editTime.addingTimeInterval(10)
        )

        #expect(snapshot?.meetingName == "Updated name")
        #expect(snapshot?.organizationId == acme)
        #expect(snapshot?.meetingSpecificContext == "Edited mid-recording")
        #expect(snapshot?.resolvedCompiledContext == "compiled-after-edit")
        #expect(snapshot?.lastEditedAt == editTime)
        #expect(store.pending == nil, "Consume should clear pending")
    }

    @Test
    func editAfterStopButBeforeConsume_isStillRespected() {
        // The recording stops, then the user opens the editor and tweaks
        // the context before the audio file finishes writing. The pipeline
        // ultimately consumes — should reflect the edit.
        let store = MeetingContextStore()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordStarted(meetingName: "Sync", at: started)

        let stopped = started.addingTimeInterval(60)
        store.recordStopped(at: stopped)

        let edited = stopped.addingTimeInterval(5)
        store.update(meetingSpecificContext: .some("Last-minute note"), at: edited)

        let fileCreated = started.addingTimeInterval(30)
        let snap = store.consume(
            forFileCreatedAt: fileCreated,
            now: edited.addingTimeInterval(1)
        )
        #expect(snap?.meetingSpecificContext == "Last-minute note")
    }
}
