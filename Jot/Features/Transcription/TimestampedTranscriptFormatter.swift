import Foundation

/// Turns `TranscriptionResult.segments` into a human-readable transcript
/// with `[HH:MM:SS]` prefixes per segment — the format we want to write
/// into the Notion meeting page so the reader can jump to specific
/// moments later. We keep this as its own value so the formatting rule
/// is exercised by a focused unit test and stays out of `NotionClient` /
/// `ProcessingPipeline` (which are already doing more interesting work).
///
/// Decisions baked in:
///   - `HH:MM:SS` always (never `MM:SS`), even for sub-hour meetings, so
///     downstream tools that parse the format don't have to branch on
///     length.
///   - Each segment's text is trimmed (Whisper emits a leading space on
///     every segment by spec) so the rendered line reads cleanly.
///   - Empty segments are dropped — the timestamp on its own conveys no
///     information.
///   - When `segments` is empty (some endpoints return `verbose_json`
///     without segment metadata), we fall back to the plain `.text` so
///     Notion still gets *something*. That fallback is the caller's job
///     — see `format(_:)`'s return value.
enum TimestampedTranscriptFormatter {

    /// Render `segments` as a single string with one `[HH:MM:SS] text`
    /// line per segment. Returns `nil` when there's nothing to render
    /// (no segments or every segment was empty after trimming) so the
    /// caller can decide whether to fall back to the plain transcript.
    static func format(_ segments: [TranscriptionResult.Segment]) -> String? {
        let lines = segments.compactMap { segment -> String? in
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return "[\(timestamp(from: segment.start))] \(trimmed)"
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Convenience: format the segments, falling back to `result.text`
    /// when there's nothing to render. This is the shape callers usually
    /// want — "give me a body string for Notion." Returns the plain text
    /// when no segments are available so the meeting page still has
    /// content even on degenerate `verbose_json` responses.
    static func formatBody(for result: TranscriptionResult) -> String {
        if let timestamped = format(result.segments) {
            return timestamped
        }
        return result.text
    }

    /// Format `totalSeconds` as `HH:MM:SS`. We clamp to non-negative to
    /// stay safe against a server that emits a negative start (would
    /// indicate a bug on their side; nothing we can do but render zero).
    /// Hours can exceed two digits in principle — a 100-hour-plus
    /// recording would render as `100:13:42`, which is still parseable.
    static func timestamp(from totalSeconds: Double) -> String {
        let clamped = max(0, totalSeconds)
        let whole = Int(clamped.rounded(.down))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let seconds = whole % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
