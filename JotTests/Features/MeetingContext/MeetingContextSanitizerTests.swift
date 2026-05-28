import Testing
import Foundation
@testable import Jot

/// Tests for `MeetingContextStore.sanitizedFilenameComponent` — the static
/// filename sanitizer used by the pipeline to turn user-typed meeting names
/// into safe filesystem components. Inherited from the now-removed
/// `MeetingNameStore`.
struct MeetingContextSanitizerTests {

    @Test
    func plainName_returnsAsIs() {
        #expect(MeetingContextStore.sanitizedFilenameComponent("Standup") == "Standup")
        #expect(MeetingContextStore.sanitizedFilenameComponent("Client Call 2026") == "Client Call 2026")
    }

    @Test
    func replacesForbiddenChars() {
        #expect(MeetingContextStore.sanitizedFilenameComponent("a/b") == "a-b")
        #expect(MeetingContextStore.sanitizedFilenameComponent("a:b") == "a-b")
        #expect(MeetingContextStore.sanitizedFilenameComponent("a\\b") == "a-b")
    }

    @Test
    func collapsesHyphenRuns() {
        #expect(MeetingContextStore.sanitizedFilenameComponent("a/:\\b") == "a-b")
    }

    @Test
    func stripsControlChars() {
        #expect(MeetingContextStore.sanitizedFilenameComponent("a\u{0007}b") == "a-b")
        #expect(MeetingContextStore.sanitizedFilenameComponent("a\nb") == "a-b")
    }

    @Test
    func trimsLeadingTrailingDotsAndWhitespace() {
        #expect(MeetingContextStore.sanitizedFilenameComponent("...Standup...") == "Standup")
        #expect(MeetingContextStore.sanitizedFilenameComponent("  Standup  ") == "Standup")
        #expect(MeetingContextStore.sanitizedFilenameComponent(" .Standup. ") == "Standup")
    }

    @Test
    func emptyAfterTrimming_returnsNil() {
        #expect(MeetingContextStore.sanitizedFilenameComponent("") == nil)
        #expect(MeetingContextStore.sanitizedFilenameComponent("   ") == nil)
        #expect(MeetingContextStore.sanitizedFilenameComponent("...") == nil)
        // "////" sanitizes to "-" → trimmed of nothing → "-" survives.
        #expect(MeetingContextStore.sanitizedFilenameComponent("////") == "-")
    }

    @Test
    func truncatesAt200Chars() {
        let long = String(repeating: "a", count: 250)
        let result = MeetingContextStore.sanitizedFilenameComponent(long)
        #expect(result?.count == 200)
    }

    @Test
    func preservesNonASCII() {
        #expect(MeetingContextStore.sanitizedFilenameComponent("Réunion équipe") == "Réunion équipe")
        #expect(MeetingContextStore.sanitizedFilenameComponent("会议") == "会议")
    }
}
