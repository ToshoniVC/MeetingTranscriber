import Testing
import Foundation
@testable import Jot

/// Unit tests for `MeetingBatchAccumulator`. Verify that:
///   - files outside any recording window pass straight through as `.single`
///   - files inside an active window are buffered, not emitted
///   - on `recordStopped` + settle, buffered parts emit as `.batch` sorted by creation date
///   - a single-part window still emits as `.single` (no batch wrapper)
///   - back-to-back `recordStarted` flushes the previous session first
///   - `stop()` flushes any buffered batch synchronously
///   - the unset emitter swallows further emits without crashing
///
/// **Time anchoring.** Tests anchor `startedAt` ~10 minutes in the past so
/// file creation dates within that window also lie in the past relative to
/// wall-clock `Date()` — the accumulator's window-membership check uses
/// `(stoppedAt ?? now) + slop` as the upper bound, and wall-clock `now` is
/// always after `startedAt + 10min`. Tests use a 50 ms settle delay so the
/// suite runs quickly.
struct MeetingBatchAccumulatorTests {

    // MARK: - Helpers

    private static let settleDelay: TimeInterval = 0.05

    /// How far in the past to anchor `startedAt` so the test's simulated
    /// recording window comfortably precedes wall-clock `now`.
    private static let pastAnchor: TimeInterval = -10 * 60

    /// Sink that captures emitted `PipelineWorkItem`s for assertions.
    private actor Sink {
        private(set) var items: [PipelineWorkItem] = []

        func record(_ item: PipelineWorkItem) {
            items.append(item)
        }

        func snapshot() -> [PipelineWorkItem] { items }
    }

    private static func makeAccumulator() async -> (MeetingBatchAccumulator, Sink) {
        let acc = MeetingBatchAccumulator(settleDelay: Self.settleDelay)
        let sink = Sink()
        await acc.setEmitter { [sink] item in
            await sink.record(item)
        }
        return (acc, sink)
    }

    private static func makeSnapshot(name: String = "Demo Meeting") -> MeetingContextSnapshot {
        MeetingContextSnapshot(
            meetingName: name,
            organizationId: nil,
            organizationName: nil,
            meetingSpecificContext: nil,
            resolvedCompiledContext: "",
            lastEditedAt: Date()
        )
    }

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/jot-acc-test/\(name)")
    }

    /// Anchor "recording started" 10 minutes in the past so simulated
    /// creation dates fall safely before wall-clock `now`.
    private static func anchoredStart() -> Date {
        Date().addingTimeInterval(Self.pastAnchor)
    }

    /// Wait long enough for the settle timer to fire on the actor and the
    /// emit closure to record into the Sink.
    private static func waitForSettle() async {
        try? await Task.sleep(nanoseconds: UInt64((Self.settleDelay + 0.05) * 1_000_000_000))
    }

    // MARK: - No-window passthrough

    @Test
    func ingest_withNoActiveSession_emitsSingle() async {
        let (acc, sink) = await Self.makeAccumulator()
        let u = Self.url("a.mp3")

        await acc.ingest(u, creationDate: Date())

        let items = await sink.snapshot()
        #expect(items == [.single(u)])
    }

    // MARK: - In-window buffering

    @Test
    func ingest_insideActiveWindow_doesNotEmit() async {
        let (acc, sink) = await Self.makeAccumulator()
        let startedAt = Self.anchoredStart()
        await acc.noteRecordingStarted(snapshot: Self.makeSnapshot(), at: startedAt)

        let part1 = Self.url("part1.mp3")
        await acc.ingest(part1, creationDate: startedAt.addingTimeInterval(60))

        let items = await sink.snapshot()
        #expect(items.isEmpty, "In-window file should be buffered, not emitted")
    }

    @Test
    func ingest_outsideWindow_evenWhenSessionActive_emitsSingle() async {
        let (acc, sink) = await Self.makeAccumulator()
        let startedAt = Self.anchoredStart()
        await acc.noteRecordingStarted(snapshot: Self.makeSnapshot(), at: startedAt)

        // Two hours BEFORE the recording started — clearly outside, even
        // with the past anchor.
        let stray = Self.url("stray.mp3")
        await acc.ingest(stray, creationDate: startedAt.addingTimeInterval(-7200))

        let items = await sink.snapshot()
        #expect(items == [.single(stray)])
    }

    // MARK: - Batch flush

    @Test
    func recordStopped_afterSettle_emitsBatchSortedByCreationDate() async {
        let (acc, sink) = await Self.makeAccumulator()
        let startedAt = Self.anchoredStart()
        let snapshot = Self.makeSnapshot(name: "Split Meeting")
        await acc.noteRecordingStarted(snapshot: snapshot, at: startedAt)

        // Three parts, ingested out of chronological order. Anchor + 0..120s
        // keeps everything safely in the past relative to wall-clock now.
        let part2 = Self.url("part2.mp3")
        let part1 = Self.url("part1.mp3")
        let part3 = Self.url("part3.mp3")
        await acc.ingest(part2, creationDate: startedAt.addingTimeInterval(60))
        await acc.ingest(part1, creationDate: startedAt.addingTimeInterval(0))
        await acc.ingest(part3, creationDate: startedAt.addingTimeInterval(120))

        await acc.noteRecordingStopped(at: startedAt.addingTimeInterval(180))
        await Self.waitForSettle()

        let items = await sink.snapshot()
        #expect(items.count == 1)
        guard case .batch(let batch) = items.first else {
            Issue.record("Expected a .batch, got \(String(describing: items.first))")
            return
        }
        #expect(batch.parts == [part1, part2, part3], "Parts should be sorted ascending by creation date")
        #expect(batch.snapshot == snapshot)
    }

    @Test
    func recordStopped_withOnePart_emitsSingleNotBatch() async {
        let (acc, sink) = await Self.makeAccumulator()
        let startedAt = Self.anchoredStart()
        await acc.noteRecordingStarted(snapshot: Self.makeSnapshot(), at: startedAt)

        let onlyPart = Self.url("only.mp3")
        await acc.ingest(onlyPart, creationDate: startedAt.addingTimeInterval(30))

        await acc.noteRecordingStopped(at: startedAt.addingTimeInterval(60))
        await Self.waitForSettle()

        let items = await sink.snapshot()
        #expect(items == [.single(onlyPart)],
                "A one-part window means no split happened — emit as .single")
    }

    @Test
    func recordStopped_withZeroParts_emitsNothing() async {
        let (acc, sink) = await Self.makeAccumulator()
        let startedAt = Self.anchoredStart()
        await acc.noteRecordingStarted(snapshot: Self.makeSnapshot(), at: startedAt)

        await acc.noteRecordingStopped(at: startedAt.addingTimeInterval(60))
        await Self.waitForSettle()

        let items = await sink.snapshot()
        #expect(items.isEmpty, "No files in the window means no emit")
    }

    @Test
    func fileArriving_afterSettleHasPassed_emitsSingle() async {
        let (acc, sink) = await Self.makeAccumulator()
        let startedAt = Self.anchoredStart()
        await acc.noteRecordingStarted(snapshot: Self.makeSnapshot(), at: startedAt)
        await acc.noteRecordingStopped(at: startedAt.addingTimeInterval(60))
        await Self.waitForSettle()

        // Stray file lands after the batch has already flushed.
        let stray = Self.url("late.mp3")
        await acc.ingest(stray, creationDate: startedAt.addingTimeInterval(30))

        let items = await sink.snapshot()
        // First the (empty) flush emitted nothing; then the late file emits as .single.
        #expect(items == [.single(stray)])
    }

    // MARK: - Back-to-back sessions

    @Test
    func recordStarted_whileSettleInFlight_flushesPreviousImmediately() async {
        let (acc, sink) = await Self.makeAccumulator()

        // Session A: two parts inside its window.
        let aStart = Self.anchoredStart()
        let snapA = Self.makeSnapshot(name: "A")
        await acc.noteRecordingStarted(snapshot: snapA, at: aStart)
        let aPart1 = Self.url("a1.mp3")
        let aPart2 = Self.url("a2.mp3")
        await acc.ingest(aPart1, creationDate: aStart.addingTimeInterval(10))
        await acc.ingest(aPart2, creationDate: aStart.addingTimeInterval(20))
        await acc.noteRecordingStopped(at: aStart.addingTimeInterval(30))

        // Before A's settle timer fires, session B starts. A should
        // flush synchronously inside `noteRecordingStarted`.
        let bStart = aStart.addingTimeInterval(31)
        let snapB = Self.makeSnapshot(name: "B")
        await acc.noteRecordingStarted(snapshot: snapB, at: bStart)

        let mid = await sink.snapshot()
        #expect(mid.count == 1, "A's batch should have flushed synchronously")
        if case .batch(let batchA) = mid.first {
            #expect(batchA.snapshot.meetingName == "A")
            #expect(batchA.parts == [aPart1, aPart2])
        } else {
            Issue.record("Expected A's flush to produce a .batch")
        }

        // Session B carries on cleanly.
        let bPart1 = Self.url("b1.mp3")
        let bPart2 = Self.url("b2.mp3")
        await acc.ingest(bPart1, creationDate: bStart.addingTimeInterval(5))
        await acc.ingest(bPart2, creationDate: bStart.addingTimeInterval(15))
        await acc.noteRecordingStopped(at: bStart.addingTimeInterval(20))
        await Self.waitForSettle()

        let all = await sink.snapshot()
        #expect(all.count == 2)
        if case .batch(let batchB) = all.last {
            #expect(batchB.snapshot.meetingName == "B")
            #expect(batchB.parts == [bPart1, bPart2])
        } else {
            Issue.record("Expected B's flush to produce a .batch")
        }
    }

    // MARK: - Dedup + shutdown

    @Test
    func ingest_sameUrlTwice_dedupedIntoSingleBatchEntry() async {
        let (acc, sink) = await Self.makeAccumulator()
        let startedAt = Self.anchoredStart()
        await acc.noteRecordingStarted(snapshot: Self.makeSnapshot(), at: startedAt)

        let part = Self.url("part1.mp3")
        let part2 = Self.url("part2.mp3")
        await acc.ingest(part, creationDate: startedAt.addingTimeInterval(5))
        await acc.ingest(part, creationDate: startedAt.addingTimeInterval(5)) // dup
        await acc.ingest(part2, creationDate: startedAt.addingTimeInterval(15))

        await acc.noteRecordingStopped(at: startedAt.addingTimeInterval(20))
        await Self.waitForSettle()

        let items = await sink.snapshot()
        guard case .batch(let batch) = items.first else {
            Issue.record("Expected a .batch")
            return
        }
        #expect(batch.parts.count == 2, "Duplicate ingests for the same URL should not double-count")
        #expect(batch.parts == [part, part2])
    }

    @Test
    func unsetEmitter_silentlyDropsFurtherEmits() async {
        let (acc, sink) = await Self.makeAccumulator()
        await acc.unsetEmitter()

        await acc.ingest(Self.url("a.mp3"), creationDate: Date())
        let items = await sink.snapshot()
        #expect(items.isEmpty, "Detached emitter should swallow ingests rather than crash")
    }

    // MARK: - Regression: settle-task self-cancellation (v0.4.3)

    /// Records `Task.isCancelled` at the moment the accumulator's emitter
    /// is called, so the regression test below can assert the timer-driven
    /// flush isn't running inside a cancelled Task.
    private actor CancelProbe {
        private(set) var observedCancellations: [Bool] = []

        func record() {
            observedCancellations.append(Task.isCancelled)
        }

        func snapshot() -> [Bool] { observedCancellations }
    }

    /// v0.4.2 had a latent bug where `flushNow` called `settleTask?.cancel()`
    /// on itself when invoked from the settle timer. Cancellation propagated
    /// into the emitter and any `URLSession` upload kicked off downstream
    /// failed with `URLError(.cancelled)` — every first-time recording
    /// transcription surfaced as "Network error: cancelled" until the user
    /// clicked Retry. This test wires a `CancelProbe` emitter so the
    /// regression is observable without a real URLSession.
    @Test
    func timerDrivenFlush_doesNotCancelOwnTask() async {
        let acc = MeetingBatchAccumulator(settleDelay: Self.settleDelay)
        let probe = CancelProbe()
        await acc.setEmitter { [probe] _ in
            await probe.record()
        }

        let startedAt = Self.anchoredStart()
        await acc.noteRecordingStarted(snapshot: Self.makeSnapshot(), at: startedAt)
        let url = Self.url("solo.mp3")
        await acc.ingest(url, creationDate: startedAt.addingTimeInterval(60))
        await acc.noteRecordingStopped(at: startedAt.addingTimeInterval(120))

        await Self.waitForSettle()

        let observed = await probe.snapshot()
        #expect(observed == [false],
                "Timer-driven flush must run the emitter on a non-cancelled Task — \(observed)")
    }

    /// Double-tap regression: a previous session's settle task must NOT
    /// fire a stray flush after a new `noteRecordingStarted` has swapped
    /// in its session. `flushNow` no longer self-cancels (see above), so
    /// `noteRecordingStarted` is now responsible for cancelling the
    /// pending settle before it draws the new session.
    @Test
    func newRecordingStarted_cancelsPriorSettleTask() async {
        let (acc, sink) = await Self.makeAccumulator()
        let startedAt1 = Self.anchoredStart()
        await acc.noteRecordingStarted(snapshot: Self.makeSnapshot(name: "First"), at: startedAt1)
        await acc.ingest(Self.url("first.mp3"), creationDate: startedAt1.addingTimeInterval(60))
        await acc.noteRecordingStopped(at: startedAt1.addingTimeInterval(120))

        // Start a second recording before the settle for the first one
        // expires — the prior settle must be cancelled so it doesn't
        // later wake up and prematurely flush the new session.
        let startedAt2 = Date().addingTimeInterval(-30)
        await acc.noteRecordingStarted(snapshot: Self.makeSnapshot(name: "Second"), at: startedAt2)
        await acc.ingest(Self.url("second.mp3"), creationDate: startedAt2.addingTimeInterval(5))

        // Wait long enough that the *first* session's settle would've
        // fired if it hadn't been cancelled.
        await Self.waitForSettle()

        let items = await sink.snapshot()
        // Only the first session's flush (triggered synchronously by the
        // second noteRecordingStarted) should have emitted; the second
        // session is still in its window.
        #expect(items.count == 1, "Expected exactly one emit (first session's flush), got \(items.count)")
        if case .single(let u) = items.first {
            #expect(u == Self.url("first.mp3"))
        } else {
            Issue.record("Expected first session to emit as .single")
        }
    }

    @Test
    func stop_flushesBufferedBatchEvenWithoutSettle() async {
        let (acc, sink) = await Self.makeAccumulator()
        let startedAt = Self.anchoredStart()
        await acc.noteRecordingStarted(snapshot: Self.makeSnapshot(), at: startedAt)

        let part1 = Self.url("part1.mp3")
        let part2 = Self.url("part2.mp3")
        await acc.ingest(part1, creationDate: startedAt.addingTimeInterval(5))
        await acc.ingest(part2, creationDate: startedAt.addingTimeInterval(15))

        // No `noteRecordingStopped` — pipeline tearing down mid-recording.
        await acc.stop()

        let items = await sink.snapshot()
        #expect(items.count == 1, "stop() must emit buffered parts so they're not silently dropped")
        if case .batch(let batch) = items.first {
            #expect(batch.parts == [part1, part2])
        } else {
            Issue.record("Expected stop()'s flush to produce a .batch")
        }
    }
}
