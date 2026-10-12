import Testing
import Foundation
@testable import Jot

/// Unit coverage for `TranscriptArtifactFilter` — prompt echo, boilerplate,
/// symbol-only lines, welded lead-ins, and duplicate collapsing — plus
/// `TranscriptionResult.filteringArtifacts`, which applies it and rebuilds
/// the transcript text. Inputs are lifted from real Jot meetings.
struct TranscriptArtifactFilterTests {

    private static let glossary = "TnT, Team n Time, Ellen Mees, Brecht Thijs, Niels Vermaut, Calidos, Alpex, Qarakter, SaaS solution in capacitymanagement for Healthcare."
    private static let index = TranscriptArtifactFilter.GlossaryIndex(glossary: glossary)

    private func seg(_ text: String, start: Double = 0, end: Double = 1) -> TranscriptionResult.Segment {
        TranscriptionResult.Segment(start: start, end: end, text: text)
    }

    private func texts(_ segments: [TranscriptionResult.Segment]) -> [String] {
        segments.map(\.text)
    }

    // MARK: - Normalization

    @Test
    func normalize_lowercasesAndStripsPunctuation() {
        #expect(TranscriptArtifactFilter.normalize("  Hello, World!  ") == "hello world")
        #expect(TranscriptArtifactFilter.normalize("Élodie—山田") == "élodie 山田")
        #expect(TranscriptArtifactFilter.normalize("...") == "")
    }

    // MARK: - Symbol-only

    @Test
    func symbolOnlySegments_areDropped() {
        for junk in ["...", "**", ".", "𝄃𝄆𝄑𝄇𝄆𝄇𝄑𝄑𝄙𝄑𝄇𝄛𝄞𝄇", "   "] {
            #expect(TranscriptArtifactFilter.cleaned(junk, glossary: nil) == nil, "\(junk) should drop")
        }
    }

    // MARK: - Boilerplate

    @Test
    func knownBoilerplate_isDroppedRegardlessOfGlossary() {
        let junk = [
            "Thank you for watching!",
            "Thanks for watching",
            "Thank you for watching! Please subscribe and like!",
            "Subtitles by the Amara.org community",
            "Undertexter från Amara.org-gemenskapen",
            "Undertextning.nu",
            "**Captions by the Amara.org community**",
            "www.thelightcare.com",
            "www.tnteam.com.nl",
            "I'm sorry for the long silence",
            "See you next time!",
            "by the Amara community The end of the recording",
            "Takk for at du så med",
        ]
        for text in junk {
            #expect(TranscriptArtifactFilter.isBoilerplate(text), "\(text) should match the denylist")
            #expect(TranscriptArtifactFilter.cleaned(text, glossary: nil) == nil, "\(text) should drop")
        }
    }

    @Test
    func boilerplateLeadIn_isStrippedFromLongerRealSentence() {
        let welded = "Thank you for watching Apsa is dat vergoed voor de woorden Mogen ze regelen met een contract"
        let out = TranscriptArtifactFilter.cleaned(welded, glossary: nil)
        #expect(out == "Apsa is dat vergoed voor de woorden Mogen ze regelen met een contract")
    }

    @Test
    func realSpeechMentioningThanks_isKept() {
        for text in ["Thank you, bye.", "Merci.", "Dank je wel voor de uitleg.", "Sorry for yesterday, by the way."] {
            #expect(!TranscriptArtifactFilter.isBoilerplate(text), "\(text) is real speech")
        }
    }

    // MARK: - Prompt echo

    @Test
    func exactGlossaryEcho_isDropped() {
        for echo in ["TnT", " TnT", "TnT TnT TnT", "SaaS solution in capacitymanagement for Healthcare.", "Ellen Mees, Brecht Thijs", "Calidos", "TnT is a", "En Alpex."] {
            #expect(TranscriptArtifactFilter.isPromptEcho(echo, glossary: Self.index), "\(echo) is echo")
        }
    }

    @Test
    func fuzzyGlossaryEcho_isDropped() {
        for echo in ["Caleidos", "Ttijs", "Aalpex", "Kalidos", "Teeam n Time"] {
            #expect(TranscriptArtifactFilter.isPromptEcho(echo, glossary: Self.index), "\(echo) is a mangled glossary term")
        }
    }

    @Test
    func realSpeech_isNotEcho() {
        let real = [
            "Dat is goed.",
            "En.",                          // substring of "Ellen" — must not match; filler alone is never echo
            "Is dat Calidos?",              // "dat" is a real non-glossary word
            "Calidos heeft dat gedaan.",    // starts with a term, has real words
            "Aalpex Day",                   // "day" is not a glossary token
            "Everything is known except personnel and IT tooling.",
            "2025",
        ]
        for text in real {
            #expect(!TranscriptArtifactFilter.isPromptEcho(text, glossary: Self.index), "\(text) is real speech")
        }
    }

    @Test
    func numbers_neverFuzzyMatch() {
        let years = TranscriptArtifactFilter.GlossaryIndex(glossary: "2026")
        #expect(!TranscriptArtifactFilter.isPromptEcho("2025", glossary: years))
        #expect(TranscriptArtifactFilter.isPromptEcho("2026", glossary: years))
    }

    @Test
    func longSegment_isNeverPureEcho() {
        // Nine glossary tokens in a row — over the token cap, so not treated
        // as echo even though every token matches.
        let text = "TnT TnT TnT TnT TnT TnT TnT TnT TnT"
        #expect(!TranscriptArtifactFilter.isPromptEcho(text, glossary: Self.index))
    }

    // MARK: - Welded lead-in

    @Test
    func repeatedGlossaryLeadIn_isStripped() {
        let welded = "TnT TnT TnT I already in the middle of the recording Yeah I thinking about that"
        let out = TranscriptArtifactFilter.cleaned(welded, glossary: Self.index)
        #expect(out == "I already in the middle of the recording Yeah I thinking about that")
    }

    @Test
    func singleGlossaryLeadIn_isKept() {
        // Real sentences start with an org or product name all the time.
        let text = "Calidos is een bedrijf met twee mensen."
        #expect(TranscriptArtifactFilter.cleaned(text, glossary: Self.index) == text)
    }

    @Test
    func leadingSpaceConvention_isPreservedAfterStripping() {
        let kept = TranscriptArtifactFilter.filter(
            [seg(" TnT TnT TnT hello world again")],
            glossary: Self.glossary
        )
        #expect(texts(kept) == [" hello world again"])
    }

    // MARK: - Collapse

    @Test
    func consecutiveIdenticalShortSegments_collapseToFirst() {
        let kept = TranscriptArtifactFilter.filter(
            [seg(" Tot ziens.", start: 0, end: 1), seg(" Tot ziens.", start: 1, end: 2),
             seg(" Tot ziens.", start: 2, end: 3), seg(" Oké.", start: 3, end: 4)],
            glossary: nil
        )
        #expect(texts(kept) == [" Tot ziens.", " Oké."])
        #expect(kept.first?.start == 0)
    }

    @Test
    func nonConsecutiveOrLongDuplicates_areKept() {
        let kept = TranscriptArtifactFilter.filter(
            [seg(" Ja."), seg(" Nee."), seg(" Ja."),
             seg(" Dat is wat ik ook denk."), seg(" Dat is wat ik ook denk.")],
            glossary: nil
        )
        #expect(kept.count == 5)
    }

    // MARK: - Whole pipeline on a real tape

    @Test
    func filter_realOverdrachtOpening_keepsOnlySpeech() {
        let tape: [TranscriptionResult.Segment] = [
            seg(" TnT", start: 0, end: 5),
            seg(" TnT", start: 5, end: 10),
            seg(" TnT is a", start: 29, end: 35),
            seg(" TnT TnT TnT I already in the middle of the recording Yeah I thinking about that", start: 96, end: 120),
            seg(" Ttijs TnT is a part of the Ttijs team.", start: 335, end: 340),
            seg(" Teea", start: 353, end: 355),
            seg(" 𝄃𝄆𝄑𝄇𝄆𝄇𝄑𝄑𝄙𝄑𝄇𝄛𝄞𝄇", start: 443, end: 450),
            seg(" invoices of personnel and tooling that still needs to be removed", start: 535, end: 556),
            seg(" Everything is known except personnel and IT tooling.", start: 566, end: 570),
            seg(" Thank you for watching!", start: 668, end: 670),
        ]
        let kept = TranscriptArtifactFilter.filter(tape, glossary: Self.glossary)
        #expect(texts(kept) == [
            " I already in the middle of the recording Yeah I thinking about that",
            " Ttijs TnT is a part of the Ttijs team.",   // mixed: too many real tokens to drop
            " Teea",                                      // not close enough to any term — kept
            " invoices of personnel and tooling that still needs to be removed",
            " Everything is known except personnel and IT tooling.",
        ])
        // Timeline-neutral: survivors keep their original timestamps.
        #expect(kept.first?.start == 96)
    }

    // MARK: - TranscriptionResult integration

    @Test
    func filteringArtifacts_rebuildsTextAndCountsDropped() {
        let result = TranscriptionResult(
            text: " TnT Dat is goed. Thank you for watching!",
            duration: 30,
            segments: [seg(" TnT"), seg(" Dat is goed."), seg(" Thank you for watching!")],
            rawJSON: Data("{}".utf8),
            providerName: "Groq",
            language: "dutch",
            droppedSegmentCount: 2
        )
        let filtered = result.filteringArtifacts(glossary: Self.glossary)
        #expect(filtered.text == "Dat is goed.")
        #expect(filtered.segments.count == 1)
        #expect(filtered.droppedSegmentCount == 4)
        #expect(filtered.filteredFraction == 0.8)
        #expect(filtered.providerName == "Groq")
        #expect(filtered.language == "dutch")
        #expect(filtered.rawJSON == result.rawJSON, "raw server body is kept verbatim")
    }

    @Test
    func filteringArtifacts_isNoOpWhenNothingMatches() {
        let result = TranscriptionResult(
            text: "Dat is goed.",
            duration: 1,
            segments: [seg(" Dat is goed.")],
            rawJSON: Data("{}".utf8)
        )
        #expect(result.filteringArtifacts(glossary: Self.glossary) == result)
    }

    // MARK: - Levenshtein

    @Test
    func levenshtein_isBoundedAndCorrect() {
        #expect(TranscriptArtifactFilter.levenshtein("calidos", "caleidos", limit: 2) == 1)
        #expect(TranscriptArtifactFilter.levenshtein("thijs", "ttijs", limit: 2) == 1)
        #expect(TranscriptArtifactFilter.levenshtein("mees", "teea", limit: 2) == 2)
        #expect(TranscriptArtifactFilter.levenshtein("mees", "alpha", limit: 2) == 3, "bounded: reports limit + 1 once exceeded")
        #expect(TranscriptArtifactFilter.levenshtein("abc", "abc", limit: 1) == 0)
        #expect(TranscriptArtifactFilter.levenshtein("", "abc", limit: 5) == 3)
    }
}
