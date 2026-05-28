import Testing
import Foundation
@testable import Jot

/// Pure-logic tests for `ContextCompiler` — section ordering per PRD §6,
/// trim + dedupe, empty input handling, and budget truncation order.
struct ContextCompilerTests {

    // MARK: - Empty path

    @Test
    func compile_noOrgAndNoMeetingContext_returnsEmpty() {
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: nil,
            organization: nil
        )
        #expect(out.isEmpty)
    }

    @Test
    func compile_noOrgAndWhitespaceMeetingContext_returnsEmpty() {
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: "  \n\t ",
            organization: nil
        )
        #expect(out.isEmpty)
    }

    @Test
    func compile_meetingContextOnly_includesPrefixAndMeetingContext() {
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: "Discussing Q3 roadmap.",
            organization: nil
        )
        #expect(out.contains(ContextCompiler.systemPrefix))
        #expect(out.contains("Discussing Q3 roadmap."))
        #expect(out.contains("Meeting: Sync"))
    }

    // MARK: - Ordering

    @Test
    func compile_orderMatchesPRDSection6() {
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
            meetingName: "Roadmap Sync",
            meetingSpecificContext: "Focus on Q3.",
            organization: org
        )

        // Each label should appear in PRD §6 order. Use range-based
        // comparisons so we're robust to formatting tweaks.
        let prefix = out.range(of: ContextCompiler.systemPrefix)!
        let identity = out.range(of: "Organization: Acme (Acme Holdings)")!
        let staff = out.range(of: "Staff: Alice")!
        let projects = out.range(of: "Projects: Phoenix")!
        let terms = out.range(of: "Terms: UX")!
        let acronyms = out.range(of: "Acronyms: MRR = Monthly Recurring Revenue")!
        let notes = out.range(of: "Notes: Pronounce Phoenix")!
        let meeting = out.range(of: "Meeting: Roadmap Sync")!
        let mc = out.range(of: "Focus on Q3.")!

        #expect(prefix.lowerBound < identity.lowerBound)
        #expect(identity.lowerBound < staff.lowerBound)
        #expect(staff.lowerBound < projects.lowerBound)
        #expect(projects.lowerBound < terms.lowerBound)
        #expect(terms.lowerBound < acronyms.lowerBound)
        #expect(acronyms.lowerBound < notes.lowerBound)
        #expect(notes.lowerBound < meeting.lowerBound)
        #expect(meeting.lowerBound < mc.lowerBound)
    }

    @Test
    func compile_identitySingularWhenNameEqualsCompany() {
        let org = Organization(name: "Acme", companyName: "Acme")
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: nil,
            organization: org
        )
        // Should render once, not "Acme (Acme)".
        #expect(out.contains("Organization: Acme"))
        #expect(!out.contains("Acme (Acme)"))
    }

    // MARK: - Trim + dedupe

    @Test
    func compile_dedupesStaffCaseInsensitively() {
        let org = Organization(
            name: "Acme",
            staffNames: ["Alice", "ALICE", "alice", "Bob", " Bob "]
        )
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: nil,
            organization: org
        )
        #expect(out.contains("Staff: Alice, Bob"))
    }

    @Test
    func compile_dropsEmptyEntries() {
        let org = Organization(
            name: "Acme",
            staffNames: ["", "  ", "Alice", "\n\t"]
        )
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: nil,
            organization: org
        )
        #expect(out.contains("Staff: Alice"))
        #expect(!out.contains("Staff: ,"))
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
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: nil,
            organization: org
        )
        // First entry for MRR wins; CAC included.
        #expect(out.contains("MRR = Monthly Recurring Revenue"))
        #expect(out.contains("CAC = Customer Acquisition Cost"))
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
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: nil,
            organization: org
        )
        #expect(out.contains("Good = All set"))
        #expect(!out.contains("Empty"))
    }

    // MARK: - Budget truncation

    @Test
    func compile_underBudget_includesEverything() {
        let org = Organization(
            name: "Acme",
            staffNames: ["Alice"],
            projectNames: ["Phoenix"],
            freeformNotes: "Short note."
        )
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: "Brief context.",
            organization: org
        )
        #expect(out.count <= ContextCompilerBudget.default.maxCharacters)
        #expect(out.contains("Alice"))
        #expect(out.contains("Phoenix"))
        #expect(out.contains("Short note."))
        #expect(out.contains("Brief context."))
    }

    @Test
    func compile_overBudget_dropsMeetingSpecificContextFirst() {
        let bigMeetingContext = String(repeating: "context-blob ", count: 100) // ~1300 chars
        let org = Organization(
            name: "Acme",
            staffNames: ["Alice"]
        )
        let budget = ContextCompilerBudget(maxCharacters: 200)
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: bigMeetingContext,
            organization: org,
            budget: budget
        )
        #expect(out.count <= 200)
        // Meeting-specific context should be dropped before org identity.
        #expect(out.contains("Organization: Acme"))
        #expect(!out.contains("context-blob"))
    }

    @Test
    func compile_overBudget_keepsOrgIdentityAlways() {
        // Massive staff list — should be dropped before identity.
        let staff = (0..<200).map { "Staff Member \($0) Full Name" }
        let org = Organization(name: "Acme", companyName: "Acme Inc.", staffNames: staff)
        let budget = ContextCompilerBudget(maxCharacters: 100)
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: nil,
            organization: org,
            budget: budget
        )
        // Org identity always wins.
        #expect(out.contains("Organization: Acme"))
    }

    @Test
    func compile_dropOrderIsBottomUp() {
        // Construct an org where every droppable section is non-trivially
        // sized so dropping one at a time noticeably shrinks the output.
        let org = Organization(
            name: "Acme",
            staffNames: ["StaffPersonOne", "StaffPersonTwo", "StaffPersonThree"],
            projectNames: ["ProjectFoo", "ProjectBar", "ProjectBaz"],
            glossaryTerms: ["TermA", "TermB", "TermC"],
            acronyms: [
                AcronymEntry(term: "AAA", expansion: "Some Long Expansion"),
            ],
            freeformNotes: "Some longer freeform notes here describing things."
        )
        // Tight budget so we have to drop multiple sections.
        let budget = ContextCompilerBudget(maxCharacters: 180)
        let out = ContextCompiler.compile(
            meetingName: "Roadmap Sync",
            meetingSpecificContext: "This sentence is the meeting-specific context.",
            organization: org,
            budget: budget
        )

        // Meeting-specific (lowest priority) should drop first.
        #expect(!out.contains("This sentence is the meeting-specific"))
        // Org identity remains.
        #expect(out.contains("Organization: Acme"))
    }

    // MARK: - Unicode / edge cases

    @Test
    func compile_unicodeNamesPreserved() {
        let org = Organization(
            name: "Acmé",
            staffNames: ["Élodie", "山田太郎", "Müller"]
        )
        let out = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: nil,
            organization: org
        )
        #expect(out.contains("Acmé"))
        #expect(out.contains("Élodie"))
        #expect(out.contains("山田太郎"))
        #expect(out.contains("Müller"))
    }

    @Test
    func compile_isPure_sameInputsSameOutput() {
        let org = Organization(
            name: "Acme",
            staffNames: ["Alice", "Bob"],
            acronyms: [AcronymEntry(term: "MRR", expansion: "Monthly Recurring Revenue")]
        )
        let a = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: "Stuff",
            organization: org
        )
        let b = ContextCompiler.compile(
            meetingName: "Sync",
            meetingSpecificContext: "Stuff",
            organization: org
        )
        #expect(a == b)
    }
}
