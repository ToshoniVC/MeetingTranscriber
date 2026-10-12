import Testing
import Foundation
@testable import Jot

/// Pure planning tests for `SilenceTrimmer` — threshold adaptation, speech
/// run detection, and the head/tail cut plan — driven by synthetic frame
/// levels so no audio is decoded.
struct SilenceTrimmerTests {

    private let settings = SilenceTrimmer.Settings.default   // 0.1 s frames, 1 s pad, 5 s min trim

    /// `count` frames at `level` dBFS.
    private func frames(_ count: Int, _ level: Float) -> [Float] {
        [Float](repeating: level, count: count)
    }

    // MARK: - Threshold

    @Test
    func threshold_digitalSilenceClampsToMinimum() {
        let levels = frames(100, -160) + frames(20, -25)
        #expect(SilenceTrimmer.speechThreshold(frameLevelsDBFS: levels) == settings.minimumThresholdDBFS)
    }

    @Test
    func threshold_sitsAboveNoiseFloor() {
        // Comfort noise at -60 dBFS for most frames → floor -60 → threshold -45.
        let levels = frames(100, -60) + frames(30, -25)
        #expect(SilenceTrimmer.speechThreshold(frameLevelsDBFS: levels) == -45)
    }

    @Test
    func threshold_clampsToMaximumInNoisyRooms() {
        let levels = frames(100, -40) + frames(30, -20)
        #expect(SilenceTrimmer.speechThreshold(frameLevelsDBFS: levels) == settings.maximumThresholdDBFS)
    }

    // MARK: - Speech bounds

    @Test
    func speechBounds_requiresAContiguousRun() {
        // A lone loud frame (click) must not count; a 3-frame run does.
        var levels = frames(200, -160)
        levels[10] = -20
        #expect(SilenceTrimmer.speechBounds(frameLevelsDBFS: levels) == nil)
        levels[100] = -20; levels[101] = -20; levels[102] = -20
        let bounds = SilenceTrimmer.speechBounds(frameLevelsDBFS: levels)
        #expect(bounds?.first == 100)
        #expect(bounds?.last == 102)
    }

    @Test
    func speechBounds_spansFirstToLastRun() {
        let levels = frames(80, -160) + frames(30, -25) + frames(200, -160) + frames(30, -25) + frames(80, -160)
        let bounds = SilenceTrimmer.speechBounds(frameLevelsDBFS: levels)
        #expect(bounds?.first == 80)
        #expect(bounds?.last == 339)
    }

    // MARK: - Plan

    @Test
    func plan_trimsHeadAndTailWithPadding() {
        // 8 s silence, 3 s speech, 8 s silence (0.1 s frames).
        let levels = frames(80, -160) + frames(30, -25) + frames(80, -160)
        let plan = SilenceTrimmer.plan(frameLevelsDBFS: levels, totalDuration: 19)
        #expect(plan?.start == 7.0)          // 8.0 - 1.0 pad
        #expect(plan?.end == 12.0)           // 11.0 + 1.0 pad
        #expect(plan?.headSeconds == 7.0)
        #expect(plan?.tailSeconds == 7.0)
    }

    @Test
    func plan_isNilWhenLessThanMinimumTrimWouldBeRemoved() {
        // 2 s silence, 3 s speech, 2 s silence → 1 s + 1 s removable < 5 s.
        let levels = frames(20, -160) + frames(30, -25) + frames(20, -160)
        #expect(SilenceTrimmer.plan(frameLevelsDBFS: levels, totalDuration: 7) == nil)
    }

    @Test
    func plan_isNilWhenNoSpeechFound() {
        #expect(SilenceTrimmer.plan(frameLevelsDBFS: frames(300, -160), totalDuration: 30) == nil)
        #expect(SilenceTrimmer.plan(frameLevelsDBFS: [], totalDuration: 0) == nil)
    }

    @Test
    func plan_neverCutsIntoSpeechWhenPaddingExceedsSilence() {
        // Speech starts at 0.5 s: head cut clamps to 0; tail still trims.
        let levels = frames(5, -160) + frames(30, -25) + frames(100, -160)
        let plan = SilenceTrimmer.plan(frameLevelsDBFS: levels, totalDuration: 13.5)
        #expect(plan?.start == 0)
        #expect(plan?.end == 4.5)
    }

    @Test
    func plan_endNeverExceedsTotalDuration() {
        let levels = frames(100, -160) + frames(30, -25)
        let plan = SilenceTrimmer.plan(frameLevelsDBFS: levels, totalDuration: 13)
        #expect(plan?.end == 13)
        #expect(plan?.tailSeconds == 0)
        #expect(plan?.headSeconds == 9)
    }
}
