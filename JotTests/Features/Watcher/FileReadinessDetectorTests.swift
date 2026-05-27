import Testing
import Foundation
@testable import Jot

/// Unit tests for the readiness state machine. Time is injected via the
/// `at:` parameter on `observe(...)`, so these tests are entirely deterministic
/// — no `Task.sleep`, no real clock.
@MainActor
struct FileReadinessDetectorTests {

    // MARK: - Fixtures

    private let url = URL(fileURLWithPath: "/tmp/meeting.mp3")
    private let snapA = FileSnapshot(size: 1_000, modificationDate: .init(timeIntervalSince1970: 1_000))
    private let snapB = FileSnapshot(size: 2_000, modificationDate: .init(timeIntervalSince1970: 1_001))

    private func t(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 100_000 + seconds)
    }

    // MARK: - Single-file flow

    @Test
    func firstObservation_returnsFalse() async {
        let detector = FileReadinessDetector(stableDuration: 2.0)
        let result = await detector.observe(url: url, snapshot: snapA, at: t(0))
        #expect(result == false)
    }

    @Test
    func sameSnapshot_beforeStableDuration_returnsFalse() async {
        let detector = FileReadinessDetector(stableDuration: 2.0)
        _ = await detector.observe(url: url, snapshot: snapA, at: t(0))
        let result = await detector.observe(url: url, snapshot: snapA, at: t(1.5))
        #expect(result == false)
    }

    @Test
    func sameSnapshot_atExactlyStableDuration_returnsTrue() async {
        let detector = FileReadinessDetector(stableDuration: 2.0)
        _ = await detector.observe(url: url, snapshot: snapA, at: t(0))
        let result = await detector.observe(url: url, snapshot: snapA, at: t(2.0))
        #expect(result == true)
    }

    @Test
    func sameSnapshot_afterStableDuration_returnsTrue() async {
        let detector = FileReadinessDetector(stableDuration: 2.0)
        _ = await detector.observe(url: url, snapshot: snapA, at: t(0))
        let result = await detector.observe(url: url, snapshot: snapA, at: t(10))
        #expect(result == true)
    }

    @Test
    func emittedFile_isNotEmittedAgain() async {
        let detector = FileReadinessDetector(stableDuration: 2.0)
        _ = await detector.observe(url: url, snapshot: snapA, at: t(0))
        let firstReady = await detector.observe(url: url, snapshot: snapA, at: t(2.0))
        let secondCall = await detector.observe(url: url, snapshot: snapA, at: t(5.0))
        #expect(firstReady == true)
        #expect(secondCall == false)
    }

    // MARK: - Snapshot changes reset the timer

    @Test
    func snapshotChanges_resetsStabilityTimer() async {
        let detector = FileReadinessDetector(stableDuration: 2.0)
        _ = await detector.observe(url: url, snapshot: snapA, at: t(0))
        _ = await detector.observe(url: url, snapshot: snapA, at: t(1.5))   // still A, not yet ready
        // File grows — this should reset the clock.
        let afterGrowth = await detector.observe(url: url, snapshot: snapB, at: t(2.0))
        #expect(afterGrowth == false)
        // Even though absolute time is now 4s past the first sighting,
        // the file's been stable on snapB only since t=2.
        let stillSettling = await detector.observe(url: url, snapshot: snapB, at: t(3.5))
        #expect(stillSettling == false)
        let nowReady = await detector.observe(url: url, snapshot: snapB, at: t(4.0))
        #expect(nowReady == true)
    }

    @Test
    func successiveChanges_keepResettingTimer() async {
        let detector = FileReadinessDetector(stableDuration: 2.0)
        for i in 0..<5 {
            let snap = FileSnapshot(size: UInt64(i * 1024), modificationDate: t(Double(i)))
            let result = await detector.observe(url: url, snapshot: snap, at: t(Double(i)))
            #expect(result == false, "Should not be ready while still growing")
        }
    }

    // MARK: - Multiple files are independent

    @Test
    func multipleFiles_haveIndependentStates() async {
        let detector = FileReadinessDetector(stableDuration: 2.0)
        let urlOne = URL(fileURLWithPath: "/tmp/one.mp3")
        let urlTwo = URL(fileURLWithPath: "/tmp/two.mp3")

        _ = await detector.observe(url: urlOne, snapshot: snapA, at: t(0))
        _ = await detector.observe(url: urlTwo, snapshot: snapB, at: t(1.0))

        let oneReady = await detector.observe(url: urlOne, snapshot: snapA, at: t(2.0))
        let twoStill = await detector.observe(url: urlTwo, snapshot: snapB, at: t(2.0))

        #expect(oneReady == true)
        #expect(twoStill == false) // only 1s since first sighting

        let twoReady = await detector.observe(url: urlTwo, snapshot: snapB, at: t(3.0))
        #expect(twoReady == true)
    }

    // MARK: - Reset / forget

    @Test
    func forget_allowsFileToBeProcessedAgain() async {
        let detector = FileReadinessDetector(stableDuration: 2.0)
        _ = await detector.observe(url: url, snapshot: snapA, at: t(0))
        _ = await detector.observe(url: url, snapshot: snapA, at: t(2.0))
        await detector.forget(url)
        // After forget, it's as if the file was never seen.
        let result = await detector.observe(url: url, snapshot: snapA, at: t(3.0))
        #expect(result == false) // first sighting again
        let ready = await detector.observe(url: url, snapshot: snapA, at: t(5.0))
        #expect(ready == true)
    }

    @Test
    func reset_clearsAllState() async {
        let detector = FileReadinessDetector(stableDuration: 2.0)
        _ = await detector.observe(url: url, snapshot: snapA, at: t(0))
        await detector.reset()
        let hasState = await detector.snapshot(for: url)
        #expect(hasState == nil)
    }
}
