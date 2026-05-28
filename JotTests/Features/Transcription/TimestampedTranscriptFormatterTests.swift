import Testing
import Foundation
@testable import Jot

/// Unit tests for the pure formatting helper that turns Whisper segments
/// into `[HH:MM:SS] text` lines for Notion.
struct TimestampedTranscriptFormatterTests {

    private static func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptionResult.Segment {
        TranscriptionResult.Segment(start: start, end: end, text: text)
    }

    // MARK: - timestamp(from:)

    @Test
    func timestamp_zero_rendersAsAllZeros() {
        #expect(TimestampedTranscriptFormatter.timestamp(from: 0) == "00:00:00")
    }

    @Test
    func timestamp_secondsOnly_rendersWithLeadingZeros() {
        #expect(TimestampedTranscriptFormatter.timestamp(from: 5) == "00:00:05")
    }

    @Test
    func timestamp_minutesAndSeconds() {
        #expect(TimestampedTranscriptFormatter.timestamp(from: 65) == "00:01:05")
    }

    @Test
    func timestamp_hoursMinutesSeconds() {
        // 1h 02m 03s
        #expect(TimestampedTranscriptFormatter.timestamp(from: 3_723) == "01:02:03")
    }

    @Test
    func timestamp_dropsFractionalSeconds() {
        #expect(TimestampedTranscriptFormatter.timestamp(from: 12.9) == "00:00:12")
    }

    @Test
    func timestamp_negativeInput_clampsToZero() {
        // Server bug — render zero rather than `[-1:-1:-1]`.
        #expect(TimestampedTranscriptFormatter.timestamp(from: -3) == "00:00:00")
    }

    // MARK: - format(_ segments:)

    @Test
    func format_emptySegments_returnsNil() {
        #expect(TimestampedTranscriptFormatter.format([]) == nil)
    }

    @Test
    func format_singleSegment_rendersOneLine() {
        let out = TimestampedTranscriptFormatter.format([Self.seg(0, 5, " Hello there")])
        #expect(out == "[00:00:00] Hello there")
    }

    @Test
    func format_multipleSegments_oneLinePerSegment() {
        let segments = [
            Self.seg(0, 5, " First."),
            Self.seg(30, 32, " Second."),
            Self.seg(125, 130, " Third.")
        ]
        let out = TimestampedTranscriptFormatter.format(segments)
        #expect(out == "[00:00:00] First.\n[00:00:30] Second.\n[00:02:05] Third.")
    }

    @Test
    func format_dropsEmptyAfterTrim() {
        // A segment whose text is whitespace contributes no information;
        // dropping it keeps the rendering clean.
        let segments = [
            Self.seg(0, 5, " Hello"),
            Self.seg(5, 6, "   "),
            Self.seg(10, 12, " World")
        ]
        let out = TimestampedTranscriptFormatter.format(segments)
        #expect(out == "[00:00:00] Hello\n[00:00:10] World")
    }

    @Test
    func format_allEmpty_returnsNil() {
        let segments = [Self.seg(0, 5, ""), Self.seg(5, 10, "   ")]
        #expect(TimestampedTranscriptFormatter.format(segments) == nil)
    }

    // MARK: - formatBody(for:)

    @Test
    func formatBody_withSegments_usesTimestampedRendering() {
        let result = TranscriptionResult(
            text: "Hello world",
            duration: 10,
            segments: [Self.seg(0, 5, " Hello world")],
            rawJSON: Data()
        )
        #expect(TimestampedTranscriptFormatter.formatBody(for: result) == "[00:00:00] Hello world")
    }

    @Test
    func formatBody_withNoSegments_fallsBackToPlainText() {
        // Some OpenAI-compatible endpoints return verbose_json without
        // segments[] — we still want Notion to receive *something*.
        let result = TranscriptionResult(
            text: "Plain fallback",
            duration: 10,
            segments: [],
            rawJSON: Data()
        )
        #expect(TimestampedTranscriptFormatter.formatBody(for: result) == "Plain fallback")
    }
}
