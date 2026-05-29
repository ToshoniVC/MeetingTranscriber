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
    private(set) var lastDescription: String?
    private(set) var lastOrganizations: [Organization] = []
    private(set) var lastDefaultOrgId: UUID?

    func askForUpload(
        sourceDescription: String,
        organizations: [Organization],
        defaultOrgId: UUID?
    ) async -> MeetingStartInputs? {
        askCount += 1
        lastDescription = sourceDescription
        lastOrganizations = organizations
        lastDefaultOrgId = defaultOrgId
        return nextResponse
    }
}

/// Test fake for `ManualUploadFilePicking`. Returns the queued URL(s)
/// or an empty array for cancellation.
///
/// Two queueing styles supported for convenience:
/// - `nextResponse: URL?` keeps the v0.5.0-era single-file ergonomics for
///   existing tests; a non-nil value becomes a one-element array.
/// - `nextResponses: [URL]` overrides for the v0.5.1 multi-file path.
///   When set non-nil, this takes precedence over `nextResponse`.
@MainActor
final class StubManualUploadFilePicker: ManualUploadFilePicking {
    var nextResponse: URL?
    var nextResponses: [URL]?
    private(set) var pickCount = 0

    func pick() async -> [URL] {
        pickCount += 1
        if let nextResponses { return nextResponses }
        return nextResponse.map { [$0] } ?? []
    }
}
