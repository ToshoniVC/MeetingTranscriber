import Testing
import Foundation
@testable import Jot

/// Pure-logic tests for `ContextCompiler` — the flat term-list layout (v0.8),
/// trim + dedupe, empty input handling, and budget truncation order.
struct ContextCompilerTests {

    // MARK: - Empty path

    @Test
    func compile_noOrgAndNoMeetingContext_returnsEmpty() {
        let out = ContextCompiler.compile(
            meetingSpecificContext: nil,
            organization: nil
        )
        #expect(out.isEmpty)
    }

    @Test
    func compile_noOrgAndWhitespaceMeetingContext_returnsEmpty() {
        let out = ContextCompiler.compile(
            meetingSpecificContext: "  \n\t ",
            organization: nil
        )
        #expect(out.isEmpty)
    }

    @Test
    func compile_meetingContextOnly_emitsJustThatText() {
        let out = ContextCompiler.compile(
            meetingSpecificContext: "Discussing Q3 roadmap.",
            organization: nil
        )
        #expect(out == "Discussing Q3 roadmap.")
    }

    // MARK: - Flat list layout

    @Test
    func compile_isOneFlatCommaSeparatedListWithNoLabels() {
        let org = Organization(
            name: "Acme",
            companyName: "Acme Holdings",
            staffNames: ["Alice"],
            projectNames: ["Phoenix"],
            glossaryTerms: ["UX"],
            acronyms: [AcronymEntry(term: "MRR", expansion: "Monthly Recurring Revenue")],
            freeformNotes: "Pronounce Phoenix /ˈfiːnɪks/."
        )
        let out = ContextCompiler.compile(
            meetingSpecificContext: "Focus on Q3.",
            organization: org,
            generalContext: "Niels"
        )
        #expect(out == "Niels, Acme, Acme Holdings, Alice, Phoenix, UX, MRR (Monthly Recurring Revenue), Focus on Q3.")
        #expect(!out.contains("\n"))
        for label in ["Organization:", "Staff:", "Projects:", "Terms:", "Acronyms:", "Notes:", "Meeting:"] {
            #expect(!out.contains(label), "label \(label) must not be rendered")
        }
    }

    @Test
    func compile_omitsFreeformNotesAndMeetingName() {
        // Prose in the prompt was echoed back over every silence; the meeting
        // name was the single most-echoed line. Neither goes to Whisper now.
        let org = Organization(
            name: "TnT",
            companyName: "Team n Time",
            freeformNotes: "SaaS solution in capacitymanagement for Healthcare."
        )
        let out = ContextCompiler.compile(meetingSpecificContext: nil, organization: org)
        #expect(out == "TnT, Team n Time")
        #expect(!out.contains("SaaS"))
    }

    @Test
    func compile_identitySingularWhenNameEqualsCompany() {
        let org = Organization(name: "Acme", companyName: "Acme")
        let out = ContextCompiler.compile(meetingSpecificContext: nil, organization: org)
        #expect(out == "Acme")
    }

    @Test
    func compile_generalContextComesFirstThenOrgThenMeetingContext() {
        let org = Organization(name: "Acme", staffNames: ["Alice"])
        let out = ContextCompiler.compile(
            meetingSpecificContext: "MEETINGCTX",
            organization: org,
            generalContext: "GLOBALCTX"
        )
        let general = out.range(of: "GLOBALCTX")!
        let identity = out.range(of: "Acme")!
        let staff = out.range(of: "Alice")!
        let meeting = out.range(of: "MEETINGCTX")!
        #expect(general.lowerBound < identity.lowerBound)
        #expect(identity.lowerBound < staff.lowerBound)
        #expect(staff.lowerBound < meeting.lowerBound)
    }

    @Test
    func compile_multilineFreeTextCollapsesToOneLine() {
        let out = ContextCompiler.compile(
            meetingSpecificContext: "Line one\n\n  Line two \nLine three",
            organization: nil
        )
        #expect(out == "Line one Line two Line three")
    }

    // MARK: - Trim + dedupe

    @Test
    func compile_dedupesStaffCaseInsensitively() {
        let org = Organization(
            name: "Acme",
            staffNames: ["Alice", "ALICE", "alice", "Bob", " Bob "]
        )
        let out = ContextCompiler.compile(meetingSpecificContext: nil, organization: org)
        #expect(out == "Acme, Alice, Bob")
    }

    @Test
    func compile_dedupesAcrossSections() {
        // The org name repeated in the glossary must not be listed twice.
        let org = Organization(name: "Calidos", glossaryTerms: ["calidos", "Otello"])
        let out = ContextCompiler.compile(meetingSpecificContext: nil, organization: org)
        #expect(out == "Calidos, Otello")
    }

    @Test
    func compile_dropsEmptyEntries() {
        let org = Organization(
            name: "Acme",
            staffNames: ["", "  ", "Alice", "\n\t"]
        )
        let out = ContextCompiler.compile(meetingSpecificContext: nil, organization: org)
        #expect(out == "Acme, Alice")
    }

    @Test
    func compile_acronymDedupedByTerm() {
        let org = Organization(
            name: "Acme",
            acronyms: [
                AcronymEntry(term: "MRR", expansion: "Monthly Recurring Revenue"),
                AcronymEntry(term: "mrr", expansion: "Mister"),
                AcronymEntry(term: "CAC", expansion: "Customer Acquisition Cost"),
            ]
        )
        let out = ContextCompiler.compile(meetingSpecificContext: nil, organization: org)
        #expect(out.contains("MRR (Monthly Recurring Revenue)"))
        #expect(out.contains("CAC (Customer Acquisition Cost)"))
        #expect(!out.contains("Mister"))
    }

    @Test
    func compile_acronymDropsEmptyExpansion() {
        let org = Organization(
            name: "Acme",
            acronyms: [
                AcronymEntry(term: "Empty", expansion: "   "),
                AcronymEntry(term: "Good", expansion: "All set"),
            ]
        )
        let out = ContextCompiler.compile(meetingSpecificContext: nil, organization: org)
        #expect(out.contains("Good (All set)"))
        #expect(!out.contains("Empty"))
    }

    // MARK: - Wrapper prefix

    @Test
    func defaultWrapperPrefix_isEmpty() {
        #expect(ContextCompiler.defaultWrapperPrefix.isEmpty)
    }

    @Test
    func compile_customWrapperPrefix_leadsTheList() {
        let out = ContextCompiler.compile(
            meetingSpecificContext: "Body.",
            organization: nil,
            wrapperPrefix: "Glossary:"
        )
        #expect(out == "Glossary: Body.")
    }

    @Test
    func compile_whitespacePrefix_isTreatedAsEmpty() {
        let out = ContextCompiler.compile(
            meetingSpecificContext: "Body text.",
            organization: nil,
            wrapperPrefix: "   "
        )
        #expect(out == "Body text.")
    }

    @Test
    func compile_generalContextOnly_isNotEmpty() {
        let out = ContextCompiler.compile(
            meetingSpecificContext: nil,
            organization: nil,
            generalContext: "Niels"
        )
        #expect(out == "Niels")
    }

    @Test
    func compile_noOrgNoMeetingNoGeneral_returnsEmptyEvenWithPrefix() {
        let out = ContextCompiler.compile(
            meetingSpecificContext: nil,
            organization: nil,
            wrapperPrefix: "Reference terms:",
            generalContext: "   "
        )
        #expect(out.isEmpty)
    }

    // MARK: - Budget truncation

    @Test
    func defaultBudget_is300Characters() {
        #expect(ContextCompilerBudget.default.maxCharacters == 300)
    }

    @Test
    func compile_underBudget_includesEverything() {
        let org = Organization(
            name: "Acme",
            staffNames: ["Alice"],
            projectNames: ["Phoenix"]
        )
        let out = ContextCompiler.compile(
            meetingSpecificContext: "Brief context.",
            organization: org
        )
        #expect(out.count <= ContextCompilerBudget.default.maxCharacters)
        #expect(out == "Acme, Alice, Phoenix, Brief context.")
    }

    @Test
    func compile_overBudget_dropsMeetingSpecificContextFirst() {
        let bigMeetingContext = String(repeating: "context-blob ", count: 100)
        let org = Organization(name: "Acme", staffNames: ["Alice"])
        let out = ContextCompiler.compile(
            meetingSpecificContext: bigMeetingContext,
            organization: org,
            budget: ContextCompilerBudget(maxCharacters: 200)
        )
        #expect(out.count <= 200)
        #expect(out == "Acme, Alice")
    }

    @Test
    func compile_overBudget_keepsOrgIdentityAlways() {
        let staff = (0..<200).map { "Staff Member \($0) Full Name" }
        let org = Organization(name: "Acme", companyName: "Acme Inc.", staffNames: staff)
        let out = ContextCompiler.compile(
            meetingSpecificContext: nil,
            organization: org,
            budget: ContextCompilerBudget(maxCharacters: 100)
        )
        #expect(out == "Acme, Acme Inc.")
    }

    @Test
    func compile_dropOrderIsMeetingThenGlossaryThenProjectsThenStaff() {
        let org = Organization(
            name: "Acme",
            staffNames: ["StaffPersonOne", "StaffPersonTwo"],
            projectNames: ["ProjectFoo", "ProjectBar"],
            glossaryTerms: ["TermA", "TermB"]
        )
        func compiled(_ budget: Int) -> String {
            ContextCompiler.compile(
                meetingSpecificContext: "This sentence is the meeting-specific context.",
                organization: org,
                budget: ContextCompilerBudget(maxCharacters: budget)
            )
        }
        // Full: 95 chars. Shrinking the budget peels sections off bottom-up.
        let full = compiled(1_000)
        #expect(full == "Acme, StaffPersonOne, StaffPersonTwo, ProjectFoo, ProjectBar, TermA, TermB, This sentence is the meeting-specific context.")
        let noMeeting = compiled(80)
        #expect(noMeeting == "Acme, StaffPersonOne, StaffPersonTwo, ProjectFoo, ProjectBar, TermA, TermB")
        let noGlossary = compiled(62)
        #expect(noGlossary == "Acme, StaffPersonOne, StaffPersonTwo, ProjectFoo, ProjectBar")
        let noProjects = compiled(40)
        #expect(noProjects == "Acme, StaffPersonOne, StaffPersonTwo")
        let identityOnly = compiled(10)
        #expect(identityOnly == "Acme")
    }

    @Test
    func compile_overBudget_generalContextStickierThanStaff() {
        let staff = (0..<80).map { "Staff Member \($0)" }
        let org = Organization(name: "Acme", staffNames: staff)
        let out = ContextCompiler.compile(
            meetingSpecificContext: nil,
            organization: org,
            generalContext: "KEEPME",
            budget: ContextCompilerBudget(maxCharacters: 120)
        )
        #expect(out.count <= 120)
        #expect(out == "KEEPME, Acme")
    }

    @Test
    func compile_identityOverBudget_hardTruncatesAtWordBoundary() {
        let org = Organization(name: "Averyveryverylongorganizationname Holdings International Group")
        let out = ContextCompiler.compile(
            meetingSpecificContext: nil,
            organization: org,
            budget: ContextCompilerBudget(maxCharacters: 45)
        )
        #expect(out.count <= 45)
        #expect(out == "Averyveryverylongorganizationname Holdings")
    }

    // MARK: - Unicode / purity

    @Test
    func compile_unicodeNamesPreserved() {
        let org = Organization(
            name: "Acmé",
            staffNames: ["Élodie", "山田太郎", "Müller"]
        )
        let out = ContextCompiler.compile(meetingSpecificContext: nil, organization: org)
        #expect(out == "Acmé, Élodie, 山田太郎, Müller")
    }

    @Test
    func compile_isPure_sameInputsSameOutput() {
        let org = Organization(
            name: "Acme",
            staffNames: ["Alice", "Bob"],
            acronyms: [AcronymEntry(term: "MRR", expansion: "Monthly Recurring Revenue")]
        )
        let a = ContextCompiler.compile(meetingSpecificContext: "Stuff", organization: org)
        let b = ContextCompiler.compile(meetingSpecificContext: "Stuff", organization: org)
        #expect(a == b)
    }
}
