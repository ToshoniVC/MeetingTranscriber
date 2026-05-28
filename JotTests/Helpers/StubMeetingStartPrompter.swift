import Foundation
@testable import Jot

/// Test fake for `MeetingStartPrompting`. Returns the queued response (or
/// nil for "user cancelled") and records what it was asked.
@MainActor
final class StubMeetingStartPrompter: MeetingStartPrompting {
    /// Response the next `ask()` call returns. Default: an empty-name
    /// inputs payload (which the caller treats as cancel). Set to a real
    /// `MeetingStartInputs` to simulate a successful prompt; set to nil
    /// to simulate the user hitting Cancel.
    var nextResponse: MeetingStartInputs? = MeetingStartInputs(meetingName: "")

    private(set) var askCount = 0
    private(set) var lastOrganizations: [Organization] = []
    private(set) var lastDefaultOrgId: UUID?

    func ask(
        organizations: [Organization],
        defaultOrgId: UUID?
    ) async -> MeetingStartInputs? {
        askCount += 1
        lastOrganizations = organizations
        lastDefaultOrgId = defaultOrgId
        return nextResponse
    }
}
