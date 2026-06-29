import Foundation

/// Pure functions that translate Jot's `(meetingName, transcript, additionalContext)`
/// triple into the JSON-shaped request body Notion expects, plus any
/// follow-up append-children requests needed when content overflows the
/// per-request 100-block limit.
///
/// PRD §4.3 fixes the page body to **exactly three toggle sections**, in
/// this order: Meeting Notes (empty), Meeting Transcript, Additional
/// Context. Each toggle name is rendered verbatim — they're not
/// configurable in v1.
enum NotionPageBuilder {

    // Notion API hard limits (https://developers.notion.com/reference/request-limits).
    static let maxRichTextContentChars = 2_000
    static let maxBlocksPerRequest = 100

    /// Section titles exposed for tests so a typo in the constant doesn't
    /// drift away from PRD §4.3's exact wording.
    enum SectionTitle {
        static let meetingNotes = "Meeting Notes"
        static let meetingTranscript = "Meeting Transcript"
        static let additionalContext = "Additional Context"
    }

    /// Output of `build(...)`: the initial `POST /v1/pages` payload plus a
    /// per-section list of overflow paragraph batches that must be appended
    /// via `PATCH /v1/blocks/{id}/children` once the page is created.
    ///
    /// `transcriptOverflow` and `contextOverflow` each contain *batches* of
    /// paragraph blocks — each batch is ≤ `maxBlocksPerRequest`, ready to
    /// be sent as one `PATCH` call. Empty arrays mean no follow-up calls
    /// are needed (the typical case).
    struct BuildResult: Equatable {
        let createPage: NotionCreatePageRequest
        let transcriptOverflow: [[NotionBlock]]
        let contextOverflow: [[NotionBlock]]
    }

    /// Build the request set for a single meeting.
    ///
    /// - Parameters:
    ///   - databaseId: target database (normalized hyphenated form).
    ///   - titlePropertyName: the name of the database's title property,
    ///     resolved at runtime via `NotionClient.describeDatabase(...)`.
    ///     Notion requires the literal property name — not a stable key —
    ///     in the create-page request.
    ///   - datePropertyName: name of the first `date`-typed property in
    ///     the database, if any. When supplied alongside `meetingDate`,
    ///     the page is stamped with that date so the database view sorts
    ///     chronologically. `nil` skips the date stamp entirely.
    ///   - meetingDate: the date to stamp into `datePropertyName`,
    ///     formatted as `YYYY-MM-DD` in the user's local time zone.
    ///     Typically `Date()` (today). `nil` skips the date stamp.
    ///   - meetingName: meeting display name. Used as the page title.
    ///   - transcript: full transcript text. Empty allowed.
    ///   - additionalContext: compiled context text. Empty allowed —
    ///     the section is still created (PRD §4.3 mandates exactly three
    ///     toggles), just with a single empty paragraph child.
    static func build(
        databaseId: String,
        titlePropertyName: String,
        datePropertyName: String? = nil,
        meetingDate: Date? = nil,
        meetingName: String,
        transcript: String,
        additionalContext: String
    ) -> BuildResult {

        // Section 1: Meeting Notes — intentionally empty per PRD §4.3.
        // Notion accepts a toggle with no children; the rendered UI shows
        // an empty expandable region the user fills in by hand.
        let notesBlock = NotionBlock.toggle(
            title: [NotionRichText(plainText: SectionTitle.meetingNotes)],
            children: []
        )

        // Section 2 + 3: Meeting Transcript and Additional Context.
        // Both get paragraph children built from the source text, split
        // into the initial 100-block batch plus overflow batches for any
        // content that doesn't fit.
        let (transcriptInitial, transcriptOverflow) = splitParagraphBatches(
            text: transcript
        )
        let transcriptBlock = NotionBlock.toggle(
            title: [NotionRichText(plainText: SectionTitle.meetingTranscript)],
            children: transcriptInitial
        )

        let (contextInitial, contextOverflow) = splitParagraphBatches(
            text: additionalContext
        )
        let contextBlock = NotionBlock.toggle(
            title: [NotionRichText(plainText: SectionTitle.additionalContext)],
            children: contextInitial
        )

        var properties: [String: NotionPropertyValue] = [
            titlePropertyName: .title([NotionRichText(plainText: meetingName)])
        ]
        if let datePropertyName, let meetingDate {
            properties[datePropertyName] = .date(isoDate: isoDateString(from: meetingDate))
        }

        let create = NotionCreatePageRequest(
            parent: NotionParent(database_id: databaseId),
            properties: properties,
            children: [notesBlock, transcriptBlock, contextBlock]
        )

        return BuildResult(
            createPage: create,
            transcriptOverflow: transcriptOverflow,
            contextOverflow: contextOverflow
        )
    }

    /// `YYYY-MM-DD` in the user's local time zone — the wall-clock date
    /// they'd expect to see on the meeting page. POSIX locale keeps the
    /// format stable regardless of user-locale settings.
    static func isoDateString(from date: Date) -> String {
        isoDateFormatter.string(from: date)
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Paragraph splitting

    /// Convert a text blob into paragraph blocks: split into ≤2000-char
    /// runs at word boundaries, wrap each in a `.paragraph` block, then
    /// group into batches of ≤100 blocks each.
    ///
    /// Returns `(initial, overflow)` where:
    /// - `initial` is the first batch (≤100 blocks) to attach in the
    ///   create-page call.
    /// - `overflow` is a list of additional batches (each ≤100 blocks)
    ///   to send via append-children calls. Empty for the common case.
    ///
    /// Empty `text` always returns a single empty paragraph as the initial
    /// batch and an empty overflow list — Notion needs the section to have
    /// a child block so it renders correctly inside the toggle.
    static func splitParagraphBatches(text: String) -> (initial: [NotionBlock], overflow: [[NotionBlock]]) {
        let blocks = paragraphBlocks(from: text)

        guard blocks.count > maxBlocksPerRequest else {
            return (blocks, [])
        }

        let initial = Array(blocks.prefix(maxBlocksPerRequest))
        var overflow: [[NotionBlock]] = []
        var remaining = Array(blocks.dropFirst(maxBlocksPerRequest))
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(maxBlocksPerRequest))
            overflow.append(batch)
            remaining.removeFirst(batch.count)
        }
        return (initial, overflow)
    }

    /// Lower-level helper: produce one paragraph block per ≤2000-char chunk
    /// of `text`, splitting on whitespace where possible. Empty input
    /// produces a single empty paragraph so the toggle isn't visually
    /// hollow.
    static func paragraphBlocks(from text: String) -> [NotionBlock] {
        let chunks = chunked(text, maxChars: maxRichTextContentChars)
        if chunks.isEmpty {
            return [.paragraph(richText: [NotionRichText(plainText: "")])]
        }
        return chunks.map { chunk in
            NotionBlock.paragraph(richText: [NotionRichText(plainText: chunk)])
        }
    }

    /// Split `text` into chunks whose UTF-16 length is ≤`maxChars`, preferring
    /// a trailing whitespace boundary inside each chunk. Falls back to a hard
    /// cut at the budget if no whitespace is found in the window. Returns an
    /// empty array for empty input (caller handles the "empty paragraph" case).
    ///
    /// **Why UTF-16, not `String.count`:** Notion validates
    /// `rich_text[].text.content.length` in UTF-16 code units (its API is a JS
    /// backend, where `String.length` counts code units). Swift's `count`
    /// measures grapheme clusters, so a chunk of ≤2000 graphemes containing
    /// emoji or other non-BMP characters can exceed 2000 UTF-16 units and get
    /// rejected with a 400. We therefore budget in UTF-16 units while still
    /// splitting only on grapheme boundaries — an emoji is never cut in half.
    static func chunked(_ text: String, maxChars: Int) -> [String] {
        guard !text.isEmpty else { return [] }

        var result: [String] = []
        var current = ""
        var currentUTF16 = 0
        // The index, within `current`, just past the last whitespace we saw.
        // A nil value means "no whitespace seen yet in this chunk."
        var lastBreak: String.Index?

        func flush(_ chunk: String) {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }

        for character in text {
            let charUTF16 = character.utf16.count

            // A single grapheme cluster can itself exceed the budget (rare —
            // e.g. a long ZWJ emoji sequence). Emit whatever we have, then let
            // the oversized cluster occupy its own chunk; Notion's limit is far
            // larger than any real grapheme so this is a theoretical safety net.
            if currentUTF16 + charUTF16 > maxChars, !current.isEmpty {
                // Prefer to break at the last whitespace boundary so we don't
                // split mid-word; fall back to a hard cut at the budget edge.
                if let lastBreak, lastBreak > current.startIndex {
                    flush(String(current[current.startIndex..<lastBreak]))
                    current = String(current[lastBreak...])
                } else {
                    flush(current)
                    current = ""
                }
                currentUTF16 = current.utf16.count
                lastBreak = nil
            }

            current.append(character)
            currentUTF16 += charUTF16
            if character.isWhitespace {
                lastBreak = current.endIndex
            }
        }

        flush(current)
        return result
    }
}
