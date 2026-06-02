import Testing
import Foundation
@testable import Jot

/// Unit coverage for `TranscriptionSegmentFilter` (the per-segment
/// hallucination heuristic) and `TranscriptionResult.filteringLikelyHallucinations`
/// (which drops segments and rebuilds the transcript text).
struct TranscriptionSegmentFilterTests {

    private func segment(
        _ text: String,
        start: Double = 0,
        end: Double = 1,
        avgLogprob: Double? = nil,
        noSpeechProb: Double? = nil,
        compressionRatio: Double? = nil
    ) -> TranscriptionResult.Segment {
        TranscriptionResult.Segment(
            start: start,
            end: end,
            text: text,
            avgLogprob: avgLogprob,
            noSpeechProb: noSpeechProb,
            compressionRatio: compressionRatio
        )
    }

    // MARK: - isLikelyHallucination

    @Test
    func silence_highNoSpeechAndLowLogprob_isHallucination() {
        let s = segment(" Names and terms", avgLogprob: -1.4, noSpeechProb: 0.92)
        #expect(TranscriptionSegmentFilter.isLikelyHallucination(s))
    }

    @Test
    func repetition_highCompressionRatio_isHallucination() {
        let s = segment(" so so so so so", compressionRatio: 3.1)
        #expect(TranscriptionSegmentFilter.isLikelyHallucination(s))
    }

    @Test
    func cleanSpeech_isNotHallucination() {
        let s = segment(" Real spoken content.", avgLogprob: -0.2, noSpeechProb: 0.05, compressionRatio: 1.4)
        #expect(!TranscriptionSegmentFilter.isLikelyHallucination(s))
    }

    @Test
    func highNoSpeechButConfident_isNotHallucination() {
        // Both conditions must hold — a confident segment in a quiet passage
        // shouldn't be nuked on no-speech alone.
        let s = segment(" Quiet but real.", avgLogprob: -0.3, noSpeechProb: 0.8)
        #expect(!TranscriptionSegmentFilter.isLikelyHallucination(s))
    }

    @Test
    func missingSignals_isNotHallucination() {
        // Endpoint omitted the quality fields — never drop on absent evidence.
        let s = segment(" No metadata here.")
        #expect(!TranscriptionSegmentFilter.isLikelyHallucination(s))
    }

    // MARK: - filteringLikelyHallucinations

    @Test
    func filtering_dropsBadSegmentsAndRebuildsText() {
        let segments = [
            segment(" Names and terms used", avgLogprob: -1.5, noSpeechProb: 0.95),
            segment(" Hello everyone.", avgLogprob: -0.2, noSpeechProb: 0.04),
            segment(" so so so so", compressionRatio: 3.5),
            segment(" Let's begin.", avgLogprob: -0.3, noSpeechProb: 0.06),
        ]
        let result = TranscriptionResult(
            text: "ignored full text",
            duration: 10,
            segments: segments,
            rawJSON: Data("{\"raw\":true}".utf8)
        )

        let filtered = result.filteringLikelyHallucinations()

        #expect(filtered.segments.count == 2)
        #expect(filtered.text == "Hello everyone. Let's begin.")
        // Surviving segments keep their original timing (timeline-neutral).
        #expect(filtered.segments.first?.start == segments[1].start)
        // rawJSON is preserved verbatim.
        #expect(filtered.rawJSON == result.rawJSON)
    }

    @Test
    func filtering_noBadSegments_returnsUnchanged() {
        let segments = [
            segment(" All good.", avgLogprob: -0.2, noSpeechProb: 0.04),
            segment(" Still good.", avgLogprob: -0.25, noSpeechProb: 0.05),
        ]
        let result = TranscriptionResult(
            text: "All good. Still good.",
            duration: 5,
            segments: segments,
            rawJSON: Data()
        )
        let filtered = result.filteringLikelyHallucinations()
        #expect(filtered == result)
    }

    @Test
    func filtering_noSegments_returnsUnchanged() {
        let result = TranscriptionResult(
            text: "text-only endpoint",
            duration: nil,
            segments: [],
            rawJSON: Data()
        )
        let filtered = result.filteringLikelyHallucinations()
        #expect(filtered == result)
    }
}
