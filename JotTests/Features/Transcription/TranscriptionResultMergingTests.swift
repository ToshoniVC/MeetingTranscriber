import Testing
import Foundation
@testable import Jot

/// Unit tests for `TranscriptionResult.merging(_:)`. Multi-part recordings
/// must end with one logical timeline — every part's segments shifted by
/// the cumulative duration of all earlier parts — so the on-disk JSON
/// and the Notion rendering read as one continuous meeting rather than
/// resetting to 00:00 at the start of each chunk.
struct TranscriptionResultMergingTests {

    private static func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptionResult.Segment {
        TranscriptionResult.Segment(start: start, end: end, text: text)
    }

    private static func result(
        text: String,
        duration: Double?,
        segments: [TranscriptionResult.Segment]
    ) -> TranscriptionResult {
        TranscriptionResult(text: text, duration: duration, segments: segments, rawJSON: Data())
    }

    // MARK: - Degenerate inputs

    @Test
    func merging_emptyList_returnsEmptyResult() {
        let merged = TranscriptionResult.merging([])
        #expect(merged.text == "")
        #expect(merged.segments.isEmpty)
        #expect(merged.duration == nil)
    }

    @Test
    func merging_singleResult_isEquivalentInTextAndSegments() {
        let r = Self.result(
            text: "solo",
            duration: 60,
            segments: [Self.seg(0, 5, " solo")]
        )
        let merged = TranscriptionResult.merging([r])
        #expect(merged.text == "solo")
        #expect(merged.segments == [Self.seg(0, 5, " solo")])
        // Duration carries over from the single part.
        #expect(merged.duration == 60)
    }

    // MARK: - Multi-part offsetting

    @Test
    func merging_twoParts_shiftsSecondPartSegmentsByFirstDuration() {
        let p1 = Self.result(
            text: "part one",
            duration: 100,
            segments: [Self.seg(0, 5, " part one")]
        )
        let p2 = Self.result(
            text: "part two",
            duration: 50,
            segments: [Self.seg(0, 5, " part two")]
        )
        let merged = TranscriptionResult.merging([p1, p2])

        #expect(merged.segments == [
            Self.seg(0, 5, " part one"),
            Self.seg(100, 105, " part two")
        ])
        // Merged text concatenates with a blank line between parts (same
        // shape pre-0.4.4 used for joined transcripts).
        #expect(merged.text == "part one\n\npart two")
        // Total duration is the sum of the parts.
        #expect(merged.duration == 150)
    }

    @Test
    func merging_threeParts_offsetsAreCumulative() {
        let p1 = Self.result(text: "a", duration: 30, segments: [Self.seg(0, 10, " a")])
        let p2 = Self.result(text: "b", duration: 40, segments: [Self.seg(0, 15, " b")])
        let p3 = Self.result(text: "c", duration: 25, segments: [Self.seg(0, 5, " c")])

        let merged = TranscriptionResult.merging([p1, p2, p3])

        // Part 3's segment starts at part1.duration + part2.duration = 70.
        #expect(merged.segments == [
            Self.seg(0, 10, " a"),
            Self.seg(30, 45, " b"),
            Self.seg(70, 75, " c")
        ])
        #expect(merged.duration == 95)
    }

    @Test
    func merging_partWithoutDuration_fallsBackToLastSegmentEnd() {
        // Some endpoints omit `duration`. Falling back to the last
        // segment's `end` keeps the offset for the next part roughly
        // correct (a few hundred ms off at worst — Whisper segments
        // tend to align with end-of-audio).
        let p1 = Self.result(text: "a", duration: nil, segments: [Self.seg(0, 12, " a")])
        let p2 = Self.result(text: "b", duration: 50, segments: [Self.seg(0, 5, " b")])

        let merged = TranscriptionResult.merging([p1, p2])
        #expect(merged.segments == [
            Self.seg(0, 12, " a"),
            Self.seg(12, 17, " b")  // shifted by part1's last segment's end
        ])
    }

    @Test
    func merging_rawJSON_isValidSyntheticVerboseJson() throws {
        // The synthesized rawJSON has to parse back into a usable
        // verbose_json shape so FileOrganizer can pretty-print it on
        // disk and downstream tools (or a person grepping) can read it.
        let p1 = Self.result(text: "a", duration: 30, segments: [Self.seg(0, 10, " a")])
        let p2 = Self.result(text: "b", duration: 20, segments: [Self.seg(0, 5, " b")])

        let merged = TranscriptionResult.merging([p1, p2])
        let json = try #require(try JSONSerialization.jsonObject(with: merged.rawJSON, options: []) as? [String: Any])

        #expect(json["text"] as? String == "a\n\nb")
        #expect(json["duration"] as? Double == 50)
        let segments = try #require(json["segments"] as? [[String: Any]])
        #expect(segments.count == 2)
        #expect(segments[0]["start"] as? Double == 0)
        #expect(segments[1]["start"] as? Double == 30)
    }
}
