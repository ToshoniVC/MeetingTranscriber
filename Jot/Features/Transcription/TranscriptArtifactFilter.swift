import Foundation

/// Drops the Whisper output that `TranscriptionSegmentFilter`'s confidence
/// heuristics cannot catch: **prompt echo** and **training-data
/// boilerplate**.
///
/// **Why the confidence filter misses these.** In a silent 30-second window
/// the cheapest continuation of the prompt is the prompt itself, so Whisper
/// emits the glossary ("TnT", "Calidos", the notes sentence) as if spoken —
/// *confidently*. Its `avg_logprob` is high and its `compression_ratio` is
/// low, so the no-speech/logprob rule never fires. Across Jot's last ten
/// real meetings roughly one segment in eight was this kind of junk, and in
/// the worst meeting four in ten. The same windows also produce YouTube
/// outro boilerplate ("Thank you for watching", Amara subtitle credits).
///
/// **What it does, in order, per segment:**
/// 1. Drops segments with no letters or digits at all (`"..."`, `"**"`,
///    runs of musical/box symbols).
/// 2. Drops short segments that match a boilerplate denylist; strips a
///    boilerplate *lead-in* from a longer real sentence.
/// 3. Drops segments whose whole text is a token-aligned substring of the
///    glossary, or whose every real token is a glossary token or a close
///    misspelling of one ("Caleidos" → "Calidos", "Ttijs" → "Thijs",
///    "Aalpex" → "Alpex"); one- and two-letter filler tokens are ignored
///    ("TnT is a" is still echo).
/// 4. Strips a leading *run* of two or more identical glossary tokens welded
///    onto a real sentence ("TnT TnT TnT I already…"). A single leading term
///    is kept — real sentences often begin with an organization or product.
/// 5. Collapses consecutive identical one- or two-word segments to the first.
///
/// Pure and timeline-neutral: surviving segments keep their `start`/`end`.
/// Matching uses the **glossary only**, never the previous-part continuation,
/// so legitimately repeated speech is never mistaken for echo.
enum TranscriptArtifactFilter {

    struct Options: Sendable, Equatable {
        /// A segment with more tokens than this is never treated as pure echo.
        var maxEchoTokens = 8
        /// A segment with more tokens than this is never dropped as boilerplate
        /// (its lead-in may still be stripped).
        var maxBoilerplateTokens = 12
        /// Fuzzy matching only applies to tokens at least this long; short
        /// tokens must match exactly.
        var fuzzyMinLength = 4
        /// Consecutive duplicates are collapsed only when this short.
        var maxCollapseTokens = 2
        /// Tokens at most this long are treated as filler by the echo rule.
        var fillerMaxLength = 2

        static let `default` = Options()
    }

    /// Normalized view of the compiled glossary for fast matching.
    struct GlossaryIndex: Sendable, Equatable {
        let paddedText: String
        let tokens: Set<String>

        init(glossary: String) {
            let normalized = TranscriptArtifactFilter.normalize(glossary)
            self.paddedText = " " + normalized + " "
            self.tokens = Set(normalized.split(separator: " ").map(String.init))
        }

        var isEmpty: Bool { tokens.isEmpty }
    }

    // MARK: - Entry point

    /// Return the segments that survive, with lead-ins stripped where
    /// applicable. `glossary` is the compiled term list that went to the
    /// endpoint (not the continuation tail); `nil` disables echo matching
    /// but keeps the boilerplate and garbage rules.
    static func filter(
        _ segments: [TranscriptionResult.Segment],
        glossary: String?,
        options: Options = .default
    ) -> [TranscriptionResult.Segment] {
        let index = glossary.map(GlossaryIndex.init(glossary:))
        var kept: [TranscriptionResult.Segment] = []
        kept.reserveCapacity(segments.count)
        var previousKey: String?

        for segment in segments {
            guard var text = cleaned(segment.text, glossary: index, options: options) else {
                continue
            }
            // Preserve Whisper's leading-space convention so `text` rebuilds
            // by plain concatenation downstream.
            if segment.text.hasPrefix(" ") && !text.hasPrefix(" ") {
                text = " " + text
            }
            let key = normalize(text)
            let tokenCount = key.split(separator: " ").count
            if tokenCount <= options.maxCollapseTokens, key == previousKey {
                continue
            }
            previousKey = key
            kept.append(TranscriptionResult.Segment(
                start: segment.start,
                end: segment.end,
                text: text,
                avgLogprob: segment.avgLogprob,
                noSpeechProb: segment.noSpeechProb,
                compressionRatio: segment.compressionRatio
            ))
        }
        return kept
    }

    // MARK: - Per-segment rules

    /// The segment's text after the single-segment rules, or `nil` when the
    /// whole segment should be dropped.
    static func cleaned(
        _ raw: String,
        glossary: GlossaryIndex?,
        options: Options = .default
    ) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Nothing pronounceable.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }

        // 2. Boilerplate.
        let tokens = normalize(text).split(separator: " ").map(String.init)
        if isBoilerplate(text) {
            if tokens.count <= options.maxBoilerplateTokens { return nil }
            text = strippingBoilerplateLeadIn(text)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        }

        guard let glossary, !glossary.isEmpty else { return text }

        // 3. Whole-segment echo.
        if isPromptEcho(text, glossary: glossary, options: options) { return nil }

        // 4. Welded repeated lead-in.
        text = strippingRepeatedGlossaryLeadIn(text, glossary: glossary, options: options)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }

    /// True when the segment is a token-aligned substring of the glossary, or
    /// is short and made only of glossary tokens / near-misses of them.
    static func isPromptEcho(
        _ text: String,
        glossary: GlossaryIndex,
        options: Options = .default
    ) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }
        if glossary.paddedText.contains(" " + normalized + " ") { return true }

        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty, tokens.count <= options.maxEchoTokens else { return false }
        // Filler tokens of one or two letters ("is", "a", "n", "en") carry
        // no information and routinely get welded onto an echo ("TnT is a").
        // They neither count for nor against; at least one real token must
        // remain and every real token must be (close to) a glossary term.
        let significant = tokens.filter { $0.count > options.fillerMaxLength }
        guard !significant.isEmpty else { return false }
        return significant.allSatisfy { matchesGlossaryToken($0, glossary: glossary, options: options) }
    }

    /// Known Whisper training-data boilerplate that appears over silence.
    /// Matched against the normalized (lowercased, punctuation-free) text,
    /// except the URL pattern which needs the raw dots.
    static func isBoilerplate(_ text: String) -> Bool {
        let normalized = normalize(text)
        if boilerplatePatterns.contains(where: { $0.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil }) {
            return true
        }
        let raw = text.lowercased()
        return urlPattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
    }

    // MARK: - Lead-in stripping

    /// Remove a boilerplate phrase from the *front* of a longer sentence
    /// ("Thank you for watching Apsa is dat vergoed…" → "Apsa is dat…").
    static func strippingBoilerplateLeadIn(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for phrase in leadInPhrases {
            let count = phrase.count
            guard words.count > count else { continue }
            let head = words.prefix(count).map { normalize($0) }
            if Array(head) == phrase {
                words.removeFirst(count)
                break
            }
        }
        return words.joined(separator: " ")
    }

    /// Strip a leading run of two or more identical glossary-matching tokens.
    static func strippingRepeatedGlossaryLeadIn(
        _ text: String,
        glossary: GlossaryIndex,
        options: Options = .default
    ) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 3 else { return text }
        let first = normalize(words[0])
        guard !first.isEmpty, matchesGlossaryToken(first, glossary: glossary, options: options) else {
            return text
        }
        var run = 1
        while run < words.count, normalize(words[run]) == first { run += 1 }
        guard run >= 2, run < words.count else { return text }
        return words.dropFirst(run).joined(separator: " ")
    }

    // MARK: - Token matching

    static func matchesGlossaryToken(
        _ token: String,
        glossary: GlossaryIndex,
        options: Options = .default
    ) -> Bool {
        if glossary.tokens.contains(token) { return true }
        // Numbers never fuzzy-match (2025 vs 2026 is a real difference).
        guard token.count >= options.fuzzyMinLength,
              !token.allSatisfy(\.isNumber) else { return false }
        let limit = token.count <= 6 ? 1 : 2
        return glossary.tokens.contains { candidate in
            candidate.count >= options.fuzzyMinLength
                && abs(candidate.count - token.count) <= limit
                && levenshtein(token, candidate, limit: limit) <= limit
        }
    }

    /// Bounded Levenshtein distance. Returns `limit + 1` as soon as the
    /// distance is known to exceed `limit`.
    static func levenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let s = Array(a), t = Array(b)
        if abs(s.count - t.count) > limit { return limit + 1 }
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[t.count]
    }

    // MARK: - Normalization

    /// Lowercase, keep letters and digits, collapse everything else to single
    /// spaces, trim. Unicode-aware so "Élodie" and "山田" survive.
    static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        for scalar in text.lowercased().unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    // MARK: - Denylist

    private static let boilerplatePatterns: [NSRegularExpression] = [
        #"\b(thank you|thanks|thank u) for (watching|listening)\b"#,
        #"\b(please )?(like and )?subscribe\b"#,
        #"\bamara\b"#,
        #"\b(undertext\w*|undertitel\w*|ondertitel\w*|subtitles? by|subtitles? made|captions? by|caption\w* door|ondertiteld door|transcribed by|vertaald door)\b"#,
        #"\bsee you (in the )?next (time|video|one)\b"#,
        #"\b(the )?end of (the |this )?(video|recording)\b"#,
        #"^(i m |i am |im )?sorry for the (long|noise|silence|wait|interruption)\b"#,
        #"\btakk for (at|ating)\b"#,
        #"\bsous titr\w*\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(https?://|www\.)|\b[a-z0-9-]+\.(com|nl|be|org|net|nu)\b"#,
        options: [.caseInsensitive]
    )

    /// Boilerplate lead-ins that get stripped from the front of a longer
    /// real sentence, as normalized token sequences.
    private static let leadInPhrases: [[String]] = [
        ["thank", "you", "for", "watching"],
        ["thanks", "for", "watching"],
        ["thank", "you", "for", "listening"],
        ["i", "m", "sorry", "for", "the", "long", "silence"],
        ["sorry", "for", "the", "long", "silence"],
    ]
}
