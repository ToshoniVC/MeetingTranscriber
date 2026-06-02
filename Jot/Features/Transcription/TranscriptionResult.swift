import Foundation

/// What `TranscriptionClient.transcribe(...)` returns. Replaces the
/// plain `String` return shipped through v0.4.3 — callers now have access
/// to `duration` + `segments` so the on-disk artifact can preserve the
/// API's full verbose response and the Notion writer can render
/// timestamped lines instead of one wall of text.
///
/// `rawJSON` is the verbatim HTTP body the server returned (decoded only
/// far enough to verify it parses). Keeping it lets `FileOrganizer`
/// pretty-print and persist the canonical response on disk without
/// risking round-trip data loss for fields we don't model here (avg
/// logprob, compression ratio, language probabilities, etc.).
struct TranscriptionResult: Sendable, Equatable {

    /// The concatenated transcript text — the same string we shipped in
    /// the old `String`-returning API. Used by the audit log message,
    /// the Claude Code routine fire, and as the fallback Notion body
    /// when there are no segments.
    let text: String

    /// Audio duration in seconds, as reported by the model. Used for the
    /// truncation-gap diagnostic log line. Nil if the server omitted
    /// the field (some OpenAI-compatible endpoints do).
    let duration: Double?

    /// Per-segment metadata in chronological order. Empty for endpoints
    /// that return `verbose_json` without segments (rare but allowed by
    /// the contract). Each segment's `start` / `end` is in seconds.
    let segments: [Segment]

    /// The verbatim HTTP body bytes. `FileOrganizer` writes a
    /// pretty-printed form of this to disk as the meeting's `.json`
    /// artifact.
    let rawJSON: Data

    /// User-visible name of the provider that produced this result
    /// (e.g., "OpenAI", "Groq"). v0.4.5+ — empty when the result came
    /// from a single-provider code path that doesn't know its source
    /// (legacy test fixtures, the Settings "Test connection" flow).
    /// Threaded through to the audit log and Notion footer for
    /// attribution, per the v0.4.5 PRD.
    var providerName: String = ""

    struct Segment: Sendable, Equatable {
        let start: Double
        let end: Double
        let text: String

        /// Per-segment quality signals from Whisper's `verbose_json`, used by
        /// `TranscriptionSegmentFilter` to drop hallucinated output (the
        /// prompt-echo / silence-noise a long quiet lead-in produces). All
        /// optional: endpoints that omit them simply opt that segment out of
        /// confidence filtering. Not carried across `merging(_:)` — filtering
        /// happens per-part before merge, so the merged result never needs
        /// them again.
        var avgLogprob: Double? = nil
        var noSpeechProb: Double? = nil
        var compressionRatio: Double? = nil
    }

    /// Drop segments that look like hallucinations and rebuild `text` from the
    /// survivors. Timeline-neutral: surviving segments keep their original
    /// `start`/`end`, so anything keyed to recording time stays aligned.
    /// `rawJSON` is intentionally left untouched — it's the verbatim server
    /// response kept for reproducibility, and it's useful to see *what* got
    /// filtered. No-op (returns `self`) when there are no segments or nothing
    /// is filtered.
    func filteringLikelyHallucinations(
        thresholds: TranscriptionSegmentFilter.Thresholds = .default
    ) -> TranscriptionResult {
        guard !segments.isEmpty else { return self }
        let kept = TranscriptionSegmentFilter.filter(segments, thresholds: thresholds)
        guard kept.count != segments.count else { return self }

        // Whisper segment text carries its own leading spacing, so the
        // server's full text is the segments concatenated. Rebuild the same
        // way, then trim the outer whitespace.
        let rebuilt = kept.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(
            text: rebuilt,
            duration: duration,
            segments: kept,
            rawJSON: rawJSON,
            providerName: providerName
        )
    }

    // MARK: - Merging (multi-part recordings)

    /// Combine results from each part of an Audio Hijack split recording
    /// into a single logical transcription. Per-part segments have their
    /// timestamps shifted by the cumulative duration of all earlier parts
    /// so a timestamped `[HH:MM:SS]` rendering reads as one continuous
    /// recording rather than each part restarting at zero.
    ///
    /// `rawJSON` is synthesized — multi-part meetings don't have a single
    /// canonical server response to preserve, so we emit a `verbose_json`-
    /// shaped object whose fields match what a hypothetical single-call
    /// response would have looked like. Unmodeled per-part fields
    /// (logprobs etc.) are NOT carried into the synthesized blob; if you
    /// need them, the per-part responses are still recoverable from the
    /// transcription log.
    ///
    /// Returns an "empty" result for an empty input list — callers
    /// should not normally hand an empty list in (the pipeline guards
    /// against this upstream) but we degrade gracefully.
    static func merging(_ parts: [TranscriptionResult]) -> TranscriptionResult {
        guard !parts.isEmpty else {
            return TranscriptionResult(text: "", duration: nil, segments: [], rawJSON: Data())
        }
        var offset: Double = 0
        var combinedSegments: [Segment] = []
        var combinedText: [String] = []
        for part in parts {
            for segment in part.segments {
                combinedSegments.append(Segment(
                    start: segment.start + offset,
                    end: segment.end + offset,
                    text: segment.text
                ))
            }
            combinedText.append(part.text)
            // Prefer the model-reported `duration` when present (most
            // accurate); fall back to the last segment's `end` (good
            // enough for offsetting the next part's segments); 0 means
            // no information and the next part starts at the current
            // offset, which is the least-wrong fallback.
            offset += part.duration ?? part.segments.last?.end ?? 0
        }
        let mergedText = combinedText.joined(separator: "\n\n")
        let mergedJSON = synthesizeVerboseJSON(
            text: mergedText,
            duration: offset,
            segments: combinedSegments
        )
        // Provider attribution for a multi-part batch: if every part
        // landed on the same provider, that's the attribution. If the
        // rotating transcriber switched providers mid-batch (provider 1
        // failed on part 2 → fellthrough to provider 2), join them with
        // " + " so the audit/Notion line is honest about it.
        let providerNames = parts.map(\.providerName).filter { !$0.isEmpty }
        var seen = Set<String>()
        let uniqueOrdered = providerNames.filter { seen.insert($0).inserted }
        return TranscriptionResult(
            text: mergedText,
            duration: offset > 0 ? offset : nil,
            segments: combinedSegments,
            rawJSON: mergedJSON,
            providerName: uniqueOrdered.joined(separator: " + ")
        )
    }

    /// Build a minimal `verbose_json` payload from synthesized fields so
    /// the on-disk merged artifact still parses as JSON. We intentionally
    /// keep the shape narrow — `text` / `duration` / `segments` — rather
    /// than fabricating values for fields we don't actually know
    /// (`language`, per-segment `avg_logprob`, etc.).
    private static func synthesizeVerboseJSON(
        text: String,
        duration: Double,
        segments: [Segment]
    ) -> Data {
        let payload: [String: Any] = [
            "text": text,
            "duration": duration,
            "segments": segments.map { segment -> [String: Any] in
                [
                    "start": segment.start,
                    "end": segment.end,
                    "text": segment.text
                ]
            }
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
    }
}
