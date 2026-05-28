import Testing
import Foundation
@testable import Jot

/// Tests for `MeetingStartInputs` — the value type carried from the
/// meeting-start prompter back to `AudioHijackController`. Mostly a sanity
/// check on the default-init behavior, since this is a value type with no
/// logic.
struct MeetingStartInputsTests {

    @Test
    func init_defaultsOrgAndContextToNil() {
        let inputs = MeetingStartInputs(meetingName: "Standup")
        #expect(inputs.meetingName == "Standup")
        #expect(inputs.organizationId == nil)
        #expect(inputs.meetingSpecificContext == nil)
    }

    @Test
    func init_preservesProvidedFields() {
        let id = UUID()
        let inputs = MeetingStartInputs(
            meetingName: "Sync",
            organizationId: id,
            meetingSpecificContext: "Notes"
        )
        #expect(inputs.organizationId == id)
        #expect(inputs.meetingSpecificContext == "Notes")
    }

    @Test
    func equatability() {
        let id = UUID()
        let a = MeetingStartInputs(meetingName: "x", organizationId: id, meetingSpecificContext: "n")
        let b = MeetingStartInputs(meetingName: "x", organizationId: id, meetingSpecificContext: "n")
        #expect(a == b)
    }
}
