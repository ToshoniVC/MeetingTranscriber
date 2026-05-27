import Foundation
@testable import Jot

/// Test fake for `MeetingNamePrompting`. Returns the queued response (or
/// nil for "user cancelled") and records that it was asked.
@MainActor
final class StubMeetingNamePrompter: MeetingNamePrompting {
    /// Response the next `ask()` call returns. Default: `""` (success with
    /// no name entered). Set to `nil` to simulate cancel.
    var nextResponse: String? = ""
    private(set) var askCount = 0

    func ask() async -> String? {
        askCount += 1
        return nextResponse
    }
}
