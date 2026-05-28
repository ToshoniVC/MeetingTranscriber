import Foundation
@testable import Jot

/// Test fake for `MeetingUploadPrompting`. Returns the queued response
/// (or nil for "user cancelled") and records what it was asked.
@MainActor
final class StubMeetingUploadPrompter: MeetingUploadPrompting {
    /// Response the next `askForUpload(...)` call returns. Set to nil
    /// to simulate the user dismissing the dialog.
    var nextResponse: MeetingStartInputs? = MeetingStartInputs(meetingName: "")

    private(set) var askCount = 0
    private(set) var lastFilename: String?
    private(set) var lastOrganizations: [Organization] = []
    private(set) var lastDefaultOrgId: UUID?

    func askForUpload(
        sourceFilename: String,
        organizations: [Organization],
        defaultOrgId: UUID?
    ) async -> MeetingStartInputs? {
        askCount += 1
        lastFilename = sourceFilename
        lastOrganizations = organizations
        lastDefaultOrgId = defaultOrgId
        return nextResponse
    }
}

/// Test fake for `ManualUploadFilePicking`. Returns the queued URL or
/// nil for cancellation.
@MainActor
final class StubManualUploadFilePicker: ManualUploadFilePicking {
    var nextResponse: URL?
    private(set) var pickCount = 0

    func pick() async -> URL? {
        pickCount += 1
        return nextResponse
    }
}
