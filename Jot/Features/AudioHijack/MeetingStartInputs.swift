import Foundation

/// Outputs of the meeting-start prompt (Phase D). Carries what the user can
/// decide at meeting-start time: name, organization, optional
/// meeting-specific context, and an optional language override.
///
/// `organizationId == nil` means the user picked the "No Organization"
/// sentinel — that's a deliberate choice, not a missing input.
///
/// `languageCode == nil` means "inherit" (organization default, then the
/// app-wide default); `TranscriptionLanguage.autoDetectCode` forces
/// auto-detection; any other value is an ISO-639-1 code.
struct MeetingStartInputs: Equatable, Sendable {
    var meetingName: String
    var organizationId: UUID?
    var meetingSpecificContext: String?
    var languageCode: String?

    init(
        meetingName: String,
        organizationId: UUID? = nil,
        meetingSpecificContext: String? = nil,
        languageCode: String? = nil
    ) {
        self.meetingName = meetingName
        self.organizationId = organizationId
        self.meetingSpecificContext = meetingSpecificContext
        self.languageCode = languageCode
    }
}
