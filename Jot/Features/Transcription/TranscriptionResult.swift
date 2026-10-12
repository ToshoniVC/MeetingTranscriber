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
/// risking round-trip data loss for fields we don't model here. When Jot
/// has to rewrite the timeline itself (multi-part merge, silence trim) the
/// JSON is synthesized instead — and since v0.8 that synthesized form
/// carries the per-segment confidence fields and the language too, so the
/// artifact stays useful for tuning the filters.
struct TranscriptionResult: Sendable, Equatable {

    /// The concatenated transcript text — the same string we shipped in
    /// the old `String`-returning API. Used by the audit log message,
    /// the Claude Code routine fire, and as the fallback Notion body
    /// when there are no segments.
    let text: String

    /// Audio duration in seconds, as reported by the model. Used for the
    /// truncation-gap diagnostic log line and for multi-part offsets. Nil
    /// if the server omitted the field (some OpenAI-compatible endpoints
    /// do).
    let duration: Double?

    /// Per-segment metadata in chronological order. Empty for endpoints
    /// that return `verbose_json` without segments (rare but allowed by
    /// the contract). Each segment's `start` / `end` is in seconds **on
    /// the original recording clock** — the pipeline shifts them back after
    /// a silence trim and forward across merged parts.
    let segments: [Segment]

    /// The verbatim HTTP body bytes, or a synthesized `verbose_json`-shaped
    /// payload when Jot rewrote the timeline. `FileOrganizer` writes a
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

    /// Language the endpoint reported in `verbose_json` (OpenAI returns a
    /// name such as `"english"`, Groq likewise). Nil when absent. Surfaced
    /// on the audit row so an auto-detect drift is visible.
    var language: String? = nil

    /// How many segments the confidence and artifact filters removed before
    /// this result reached the caller. Summed across merged parts so the
    /// audit row can report "12% filtered" for the whole meeting.
    var droppedSegmentCount: Int = 0

    struct Segment: Sendable, Equatable {
        let start: Double
        let end: Double
        let text: String

        /// Per-segment quality signals from Whisper's `verbose_json`, used by
        /// `TranscriptionSegmentFilter` to drop hallucinated output (the
        /// prompt-echo / silence-noise a long quiet lead-in produces). All
        /// optional: endpoints that omit them simply opt that segment out of
        /// confidence filtering. Carried across `merging(_:)` and into the
        /// synthesized JSON so the on-disk artifact keeps them.
        var avgLogprob: Double? = nil
        var noSpeechProb: Double? = nil
        var compressionRatio: Double? = nil
    }

    /// Fraction of all segments (kept + dropped) that the filters removed,
    /// in `0...1`. Nil when there is nothing to report.
    var filteredFraction: Double? {
        let total = segments.count + droppedSegmentCount
        guard total > 0, droppedSegmentCount > 0 else { return nil }
        return Double(droppedSegmentCount) / Double(total)
    }

    // MARK: - Filtering

    /// Drop segments that look like hallucinations by their confidence
    /// signals and rebuild `text` from the survivors. Timeline-neutral:
    /// surviving segments keep their original `start`/`end`, so anything
    /// keyed to recording time stays aligned. `rawJSON` is intentionally
    /// left untouched — it's the verbatim server response kept for
    /// reproducibility, and it's useful to see *what* got filtered. No-op
    /// (returns `self`) when there are no segments or nothing is filtered.
    func filteringLikelyHallucinations(
        thresholds: TranscriptionSegmentFilter.Thresholds = .default
    ) -> TranscriptionResult {
        guard !segments.isEmpty else { return self }
        let kept = TranscriptionSegmentFilter.filter(segments, thresholds: thresholds)
        guard kept.count != segments.count else { return self }
        return rebuilt(with: kept)
    }

    /// Drop prompt echo, boilerplate, and symbol-only segments via
    /// `TranscriptArtifactFilter`, rebuilding `text` from the survivors.
    /// `glossary` is the compiled term list that was sent (never the
    /// previous-part continuation). Same timeline-neutral / raw-JSON
    /// contract as `filteringLikelyHallucinations`; no-op when nothing
    /// changes.
    func filteringArtifacts(
        glossary: String?,
        options: TranscriptArtifactFilter.Options = .default
    ) -> TranscriptionResult {
        guard !segments.isEmpty else { return self }
        let kept = TranscriptArtifactFilter.filter(segments, glossary: glossary, options: options)
        guard kept != segments else { return self }
        return rebuilt(with: kept)
    }

    /// Replace `segments` with `kept`, rebuild `text` the way the server
    /// does (segments concatenated — Whisper segment text carries its own
    /// leading space), and account for the dropped count.
    private func rebuilt(with kept: [Segment]) -> TranscriptionResult {
        let rebuiltText = kept.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(
            text: rebuiltText,
            duration: duration,
            segments: kept,
            rawJSON: rawJSON,
            providerName: providerName,
            language: language,
            droppedSegmentCount: droppedSegmentCount + (segments.count - kept.count)
        )
    }

    // MARK: - Recording clock

    /// Put a result produced from a head-trimmed upload back on the
    /// original recording clock: every segment shifts later by `headOffset`
    /// and the duration becomes the untrimmed part's. Downstream timing
    /// (Notion `[HH:MM:SS]`, multi-part merge offsets, screenshot alignment)
    /// never sees that a trim happened. `rawJSON` is re-synthesized because
    /// the server's verbatim timestamps are on the trimmed clock.
    func restoringRecordingClock(
        headOffset: Double,
        originalDuration: Double?
    ) -> TranscriptionResult {
        let shifted = segments.map { segment in
            Segment(
                start: segment.start + headOffset,
                end: segment.end + headOffset,
                text: segment.text,
                avgLogprob: segment.avgLogprob,
                noSpeechProb: segment.noSpeechProb,
                compressionRatio: segment.compressionRatio
            )
        }
        let restoredDuration = originalDuration ?? duration.map { $0 + headOffset }
        return TranscriptionResult(
            text: text,
            duration: restoredDuration,
            segments: shifted,
            rawJSON: Self.synthesizeVerboseJSON(
                text: text,
                duration: restoredDuration,
                language: language,
                segments: shifted,
                extras: ["trimmed_head_seconds": headOffset]
            ),
            providerName: providerName,
            language: language,
            droppedSegmentCount: droppedSegmentCount
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
    /// response would have looked like, including the per-segment confidence
    /// fields and the reported language, so the on-disk artifact keeps
    /// enough signal to tune the filters.
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
        var dropped = 0
        for part in parts {
            for segment in part.segments {
                combinedSegments.append(Segment(
                    start: segment.start + offset,
                    end: segment.end + offset,
                    text: segment.text,
                    avgLogprob: segment.avgLogprob,
                    noSpeechProb: segment.noSpeechProb,
                    compressionRatio: segment.compressionRatio
                ))
            }
            combinedText.append(part.text)
            dropped += part.droppedSegmentCount
            // Prefer the model-reported `duration` when present (most
            // accurate); fall back to the last segment's `end` (good
            // enough for offsetting the next part's segments); 0 means
            // no information and the next part starts at the current
            // offset, which is the least-wrong fallback.
            offset += part.duration ?? part.segments.last?.end ?? 0
        }
        let mergedText = combinedText.joined(separator: "\n\n")
        // Language: the first part that reported one. Parts of one meeting
        // share a language; a disagreement is itself a sign of drift and the
        // per-part responses stay in the log for that.
        let language = parts.lazy.compactMap(\.language).first { !$0.isEmpty }
        let mergedJSON = synthesizeVerboseJSON(
            text: mergedText,
            duration: offset > 0 ? offset : nil,
            language: language,
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
            providerName: uniqueOrdered.joined(separator: " + "),
            language: language,
            droppedSegmentCount: dropped
        )
    }

    /// Build a `verbose_json`-shaped payload from the fields we model so the
    /// on-disk artifact still parses as JSON and keeps the confidence
    /// signals. Fields we don't know are omitted rather than fabricated.
    static func synthesizeVerboseJSON(
        text: String,
        duration: Double?,
        language: String?,
        segments: [Segment],
        extras: [String: Any] = [:]
    ) -> Data {
        var payload: [String: Any] = [
            "text": text,
            "segments": segments.map { segment -> [String: Any] in
                var entry: [String: Any] = [
                    "start": segment.start,
                    "end": segment.end,
                    "text": segment.text
                ]
                if let value = segment.avgLogprob { entry["avg_logprob"] = value }
                if let value = segment.noSpeechProb { entry["no_speech_prob"] = value }
                if let value = segment.compressionRatio { entry["compression_ratio"] = value }
                return entry
            }
        ]
        if let duration { payload["duration"] = duration }
        if let language { payload["language"] = language }
        for (key, value) in extras { payload[key] = value }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
    }
}
