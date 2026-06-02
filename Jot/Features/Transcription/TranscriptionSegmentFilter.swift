import Foundation

/// Drops Whisper hallucination segments using the per-segment quality signals
/// the model already returns in `verbose_json`.
///
/// **Why this exists.** When a recording opens (or trails off) with silence,
/// Whisper has nothing to transcribe and falls back to emitting noise — often
/// the prompt echoed back as if spoken, subtitle-credit boilerplate, or a
/// repetition loop. Those segments carry tell-tale signals: a high
/// `no_speech_prob`, a very low `avg_logprob` (the model isn't confident), or
/// an abnormally high `compression_ratio` (the text repeats itself). The
/// thresholds below are the long-standing Whisper defaults for exactly this.
///
/// Pure and timeline-neutral: it only removes whole segments, never shifts
/// timestamps, so screenshot/transcript alignment is unaffected.
enum TranscriptionSegmentFilter {

    /// Tunable cutoffs. Defaults match Whisper's own no-speech / repetition
    /// heuristics. Exposed so tests can pin exact behavior.
    struct Thresholds: Equatable, Sendable {
        /// Above this `no_speech_prob` *and* below `avgLogprob`, a segment is
        /// treated as silence noise. Both must hold — high no-speech alone, on
        /// genuinely quiet-but-real speech, shouldn't nuke a segment.
        var noSpeechProb: Double = 0.6
        /// The `avg_logprob` floor paired with `noSpeechProb`.
        var avgLogprob: Double = -1.0
        /// Above this `compression_ratio` the text repeats itself enough to be
        /// a decoder loop, independent of the no-speech signal.
        var compressionRatio: Double = 2.4

        static let `default` = Thresholds()
    }

    /// True when `segment` looks like a hallucination under `thresholds`.
    /// Missing signals are treated as "no evidence" — a segment is never
    /// dropped on a field the endpoint didn't provide.
    static func isLikelyHallucination(
        _ segment: TranscriptionResult.Segment,
        thresholds: Thresholds = .default
    ) -> Bool {
        if let noSpeech = segment.noSpeechProb,
           let logprob = segment.avgLogprob,
           noSpeech > thresholds.noSpeechProb,
           logprob < thresholds.avgLogprob {
            return true
        }
        if let compression = segment.compressionRatio,
           compression > thresholds.compressionRatio {
            return true
        }
        return false
    }

    /// Return only the segments that don't look like hallucinations.
    static func filter(
        _ segments: [TranscriptionResult.Segment],
        thresholds: Thresholds = .default
    ) -> [TranscriptionResult.Segment] {
        segments.filter { !isLikelyHallucination($0, thresholds: thresholds) }
    }
}
