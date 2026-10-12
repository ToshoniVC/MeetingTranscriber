import Foundation

/// The two halves of the Whisper `prompt` field, kept apart so the echo
/// filter can match against the glossary alone.
///
/// - `glossary`: the compiled per-meeting term list (`ContextCompiler`).
///   Spelling guidance for names and jargon. It is also exactly what Whisper
///   regurgitates over silence, so `TranscriptArtifactFilter` uses it as
///   the echo reference.
/// - `continuation`: the tail of the previous part's (already filtered)
///   transcript. This is what the `prompt` field was designed for — the
///   preceding text — and it gives the decoder continuity across Audio
///   Hijack's part boundaries. It is never used for echo matching, because
///   genuinely repeated speech must survive.
///
/// `rendered` is the string that goes on the wire: glossary first, then the
/// continuation on its own line. Whisper keeps the *last* 224 tokens of an
/// over-long prompt, so the budgets below are sized to keep the total under
/// that for Dutch (which tokenizes at roughly three characters per token).
struct TranscriptionPrompt: Sendable, Equatable {

    var glossary: String?
    var continuation: String?

    /// Characters of previous-part text carried into the next part's
    /// prompt. Together with `ContextCompilerBudget.default` (300) this
    /// stays under Whisper's 224-token window for Dutch.
    static let continuationBudget = 400

    static let empty = TranscriptionPrompt(glossary: nil, continuation: nil)

    init(glossary: String? = nil, continuation: String? = nil) {
        self.glossary = Self.clean(glossary)
        self.continuation = Self.clean(continuation)
    }

    /// Wire form, or `nil` when there's nothing to send (the request then
    /// omits the field entirely).
    var rendered: String? {
        switch (glossary, continuation) {
        case (nil, nil): return nil
        case (let g?, nil): return g
        case (nil, let c?): return c
        case (let g?, let c?): return g + "\n" + c
        }
    }

    /// Same glossary, new continuation. Used per part / per chunk.
    func continuing(from previousText: String?) -> TranscriptionPrompt {
        TranscriptionPrompt(
            glossary: glossary,
            continuation: previousText.flatMap { Self.continuationTail(of: $0) }
        )
    }

    /// The last `maxCharacters` of `text`, cut forward to a word boundary
    /// so the prompt never starts mid-word. Newlines collapse to spaces —
    /// the merged transcript joins parts with blank lines, and a prompt
    /// should read as one run of speech. `nil` when nothing usable remains.
    static func continuationTail(
        of text: String,
        maxCharacters: Int = continuationBudget
    ) -> String? {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        guard flattened.count > maxCharacters else { return flattened }

        let cut = flattened.index(flattened.endIndex, offsetBy: -maxCharacters)
        // If the cut lands mid-word, advance to the next whitespace so the
        // tail begins on a whole word. A cut that already sits on a word
        // boundary (preceded by whitespace) keeps that word.
        var start = cut
        let landsMidWord = cut > flattened.startIndex
            && !flattened[flattened.index(before: cut)].isWhitespace
        if landsMidWord {
            while start < flattened.endIndex, !flattened[start].isWhitespace {
                start = flattened.index(after: start)
            }
        }
        let tail = flattened[start...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? nil : tail
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
