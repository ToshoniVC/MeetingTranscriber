import Testing
import Foundation
@testable import Jot

/// Unit tests for `TranscriptionPrompt` — rendering of glossary +
/// continuation and the word-boundary tail cut.
struct TranscriptionPromptTests {

    @Test
    func rendered_isNilWhenBothHalvesEmpty() {
        #expect(TranscriptionPrompt(glossary: nil, continuation: nil).rendered == nil)
        #expect(TranscriptionPrompt(glossary: "  ", continuation: "\n").rendered == nil)
        #expect(TranscriptionPrompt.empty.rendered == nil)
    }

    @Test
    func rendered_glossaryOnly_isTheGlossary() {
        #expect(TranscriptionPrompt(glossary: "Calidos, Otello").rendered == "Calidos, Otello")
    }

    @Test
    func rendered_both_putsGlossaryFirstThenContinuationOnNewLine() {
        let prompt = TranscriptionPrompt(glossary: "Calidos", continuation: "dat is goed.")
        #expect(prompt.rendered == "Calidos\ndat is goed.")
    }

    @Test
    func continuing_keepsGlossaryAndReplacesContinuation() {
        let base = TranscriptionPrompt(glossary: "Calidos", continuation: "old tail")
        let next = base.continuing(from: "the new part's text")
        #expect(next.glossary == "Calidos")
        #expect(next.continuation == "the new part's text")
        #expect(base.continuing(from: nil).continuation == nil)
        #expect(base.continuing(from: "   ").continuation == nil)
    }

    @Test
    func continuationTail_shortTextIsReturnedWhole() {
        #expect(TranscriptionPrompt.continuationTail(of: "Dat is goed.") == "Dat is goed.")
    }

    @Test
    func continuationTail_cutsForwardToWordBoundary() {
        let text = "alpha beta gamma delta epsilon"
        // 12 chars back lands inside "delta"; the tail starts at "epsilon".
        #expect(TranscriptionPrompt.continuationTail(of: text, maxCharacters: 12) == "epsilon")
        // Exactly on a boundary keeps the whole word.
        #expect(TranscriptionPrompt.continuationTail(of: text, maxCharacters: 13) == "delta epsilon")
    }

    @Test
    func continuationTail_flattensNewlinesFromMergedParts() {
        let merged = "part one text\n\npart two text\nmore"
        #expect(TranscriptionPrompt.continuationTail(of: merged) == "part one text part two text more")
    }

    @Test
    func continuationTail_nilForEmpty() {
        #expect(TranscriptionPrompt.continuationTail(of: "  \n ") == nil)
    }

    @Test
    func continuationBudget_staysUnderWhisperWindowWithGlossaryBudget() {
        // ~3 chars/token for Dutch: 300 + 400 chars ≈ 233 tokens worst case,
        // and Whisper keeps the *last* 224, so the glossary head is what
        // would be clipped first. Keep the sum conservative.
        #expect(ContextCompilerBudget.default.maxCharacters + TranscriptionPrompt.continuationBudget <= 700)
    }
}
