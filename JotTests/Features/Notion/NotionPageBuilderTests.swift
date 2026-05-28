import Testing
import Foundation
@testable import Jot

/// Exhaustive tests for `NotionPageBuilder` — the pure builder that maps
/// `(meetingName, transcript, additionalContext)` to the Notion JSON
/// request body and any overflow batches.
///
/// PRD §4.3 fixes the page body to exactly three toggle sections, in this
/// order: Meeting Notes (empty), Meeting Transcript, Additional Context.
/// These tests pin every part of that contract.
struct NotionPageBuilderTests {

    private let dbId = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
    private let titleProp = "Name"

    // MARK: - Section count + order

    @Test
    func build_produces_exactlyThreeTopLevelToggles_inOrder() {
        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: titleProp,
            meetingName: "Test Meeting",
            transcript: "hello",
            additionalContext: "context"
        )

        #expect(result.createPage.children.count == 3)

        let titles = result.createPage.children.compactMap { block -> String? in
            if case .toggle(let title, _) = block {
                return title.first?.text.content
            }
            return nil
        }
        #expect(titles == [
            NotionPageBuilder.SectionTitle.meetingNotes,
            NotionPageBuilder.SectionTitle.meetingTranscript,
            NotionPageBuilder.SectionTitle.additionalContext
        ])
    }

    @Test
    func sectionTitles_matchPRDExactly() {
        // PRD §4.3 mandates these exact strings — pin them so a typo
        // can't drift the user-visible names.
        #expect(NotionPageBuilder.SectionTitle.meetingNotes == "Meeting Notes")
        #expect(NotionPageBuilder.SectionTitle.meetingTranscript == "Meeting Transcript")
        #expect(NotionPageBuilder.SectionTitle.additionalContext == "Additional Context")
    }

    // MARK: - Meeting Notes is empty

    @Test
    func meetingNotesToggle_isEmpty() {
        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: titleProp,
            meetingName: "x",
            transcript: "irrelevant",
            additionalContext: "irrelevant"
        )
        guard case .toggle(_, let children) = result.createPage.children[0] else {
            Issue.record("First section was not a toggle")
            return
        }
        #expect(children.isEmpty)
    }

    // MARK: - Title property

    @Test
    func build_populatesTitleProperty_underProvidedKey() {
        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: "Custom Title",
            meetingName: "Q3 Planning",
            transcript: "",
            additionalContext: ""
        )
        guard case .title(let runs) = result.createPage.properties["Custom Title"] else {
            Issue.record("Title property not set under provided key")
            return
        }
        #expect(runs.count == 1)
        #expect(runs.first?.text.content == "Q3 Planning")
    }

    @Test
    func build_setsDatabaseIdOnParent() {
        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: titleProp,
            meetingName: "x",
            transcript: "",
            additionalContext: ""
        )
        #expect(result.createPage.parent.database_id == dbId)
    }

    // MARK: - Empty inputs

    @Test
    func emptyTranscript_stillCreatesTranscriptSection_withSingleEmptyParagraph() {
        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: titleProp,
            meetingName: "x",
            transcript: "",
            additionalContext: "context"
        )
        guard case .toggle(_, let children) = result.createPage.children[1] else {
            Issue.record("Transcript section was not a toggle")
            return
        }
        #expect(children.count == 1)
        guard case .paragraph(let runs) = children.first else {
            Issue.record("Transcript child was not a paragraph")
            return
        }
        #expect(runs.first?.text.content == "")
    }

    @Test
    func emptyAdditionalContext_stillCreatesContextSection_withSingleEmptyParagraph() {
        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: titleProp,
            meetingName: "x",
            transcript: "transcript",
            additionalContext: ""
        )
        guard case .toggle(_, let children) = result.createPage.children[2] else {
            Issue.record("Context section was not a toggle")
            return
        }
        #expect(children.count == 1)
        guard case .paragraph(let runs) = children.first else {
            Issue.record("Context child was not a paragraph")
            return
        }
        #expect(runs.first?.text.content == "")
    }

    // MARK: - Single-paragraph fast path

    @Test
    func shortTranscript_isWrittenAsOneParagraphBlock() {
        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: titleProp,
            meetingName: "x",
            transcript: "Just a short transcript.",
            additionalContext: ""
        )
        guard case .toggle(_, let children) = result.createPage.children[1] else {
            Issue.record("Transcript section was not a toggle")
            return
        }
        #expect(children.count == 1)
        guard case .paragraph(let runs) = children.first else {
            Issue.record("Transcript child was not a paragraph")
            return
        }
        #expect(runs.first?.text.content == "Just a short transcript.")
    }

    // MARK: - Chunking at 2000-char boundary

    @Test
    func transcriptOver2000Chars_isSplitIntoMultipleParagraphs() {
        // Build a transcript of ~5000 chars with word boundaries.
        let word = "lorem ipsum dolor sit amet consectetur "
        let transcript = String(repeating: word, count: 130) // ~5070 chars

        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: titleProp,
            meetingName: "x",
            transcript: transcript,
            additionalContext: ""
        )
        guard case .toggle(_, let children) = result.createPage.children[1] else {
            Issue.record("Transcript section was not a toggle")
            return
        }
        // ~5070 / 2000 = at least 3 chunks.
        #expect(children.count >= 3)
        // No paragraph exceeds the 2000-char rich-text limit.
        for block in children {
            guard case .paragraph(let runs) = block else { continue }
            for run in runs {
                #expect(run.text.content.count <= NotionPageBuilder.maxRichTextContentChars)
            }
        }
        // Concatenation preserves the text (modulo whitespace at split
        // points — we trim joins by design).
        let recombined = children.compactMap { block -> String? in
            if case .paragraph(let runs) = block { return runs.first?.text.content }
            return nil
        }.joined(separator: " ")
        // Strip whitespace from both for an order-preserving check.
        let strippedOriginal = transcript.filter { !$0.isWhitespace }
        let strippedRecombined = recombined.filter { !$0.isWhitespace }
        #expect(strippedRecombined == strippedOriginal)
    }

    // MARK: - Overflow batching at 100-block boundary

    @Test
    func transcriptOver100Paragraphs_overflowsIntoBatches() {
        // 150 chunks needed → 100 initial + 50 overflow.
        // Each chunk needs to exceed ~1000 chars (the split heuristic
        // takes the second half once a whitespace boundary is found),
        // so we use a string with no whitespace and length 1900 to force
        // a chunk per "paragraph segment".
        let noSpaceChunk = String(repeating: "a", count: 1_900)
        // Join them with single spaces so the chunker splits on them.
        let transcript = Array(repeating: noSpaceChunk, count: 150).joined(separator: " ")

        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: titleProp,
            meetingName: "x",
            transcript: transcript,
            additionalContext: ""
        )

        guard case .toggle(_, let children) = result.createPage.children[1] else {
            Issue.record("Transcript section was not a toggle")
            return
        }
        #expect(children.count == NotionPageBuilder.maxBlocksPerRequest)
        #expect(result.transcriptOverflow.count >= 1)
        let overflowTotal = result.transcriptOverflow.reduce(0) { $0 + $1.count }
        #expect(overflowTotal >= 50)
        // Each overflow batch is ≤100.
        for batch in result.transcriptOverflow {
            #expect(batch.count <= NotionPageBuilder.maxBlocksPerRequest)
        }
        // Context overflow stays empty.
        #expect(result.contextOverflow.isEmpty)
    }

    @Test
    func contextOverflow_isReportedInContextOverflowField() {
        let noSpaceChunk = String(repeating: "b", count: 1_900)
        let context = Array(repeating: noSpaceChunk, count: 150).joined(separator: " ")
        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: titleProp,
            meetingName: "x",
            transcript: "",
            additionalContext: context
        )

        guard case .toggle(_, let children) = result.createPage.children[2] else {
            Issue.record("Context section was not a toggle")
            return
        }
        #expect(children.count == NotionPageBuilder.maxBlocksPerRequest)
        #expect(result.contextOverflow.count >= 1)
        #expect(result.transcriptOverflow.isEmpty)
    }

    // MARK: - JSON encoding sanity

    @Test
    func createPagePayload_encodesToCorrectJSONShape() throws {
        let result = NotionPageBuilder.build(
            databaseId: dbId,
            titlePropertyName: titleProp,
            meetingName: "Hello",
            transcript: "Body.",
            additionalContext: ""
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result.createPage)
        let json = try #require(String(data: data, encoding: .utf8))

        // Parent
        #expect(json.contains("\"parent\":{\"database_id\":\"\(dbId)\"}"))
        // Title property
        #expect(json.contains("\"\(titleProp)\""))
        #expect(json.contains("\"content\":\"Hello\""))
        // Three top-level blocks with the right titles.
        #expect(json.contains("\"content\":\"\(NotionPageBuilder.SectionTitle.meetingNotes)\""))
        #expect(json.contains("\"content\":\"\(NotionPageBuilder.SectionTitle.meetingTranscript)\""))
        #expect(json.contains("\"content\":\"\(NotionPageBuilder.SectionTitle.additionalContext)\""))
        // Each block declares itself as "block" + has a toggle wrapper.
        #expect(json.contains("\"object\":\"block\""))
        #expect(json.contains("\"type\":\"toggle\""))
    }
}
