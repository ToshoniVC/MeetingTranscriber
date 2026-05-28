import Foundation

/// Outputs of the meeting-start prompt (Phase D). Carries the three things
/// the user can decide at meeting-start time: name, organization, and
/// optional meeting-specific context.
///
/// `organizationId == nil` means the user picked the "No Organization"
/// sentinel — that's a deliberate choice, not a missing input.
struct MeetingStartInputs: Equatable, Sendable {
    var meetingName: String
    var organizationId: UUID?
    var meetingSpecificContext: String?

    init(
        meetingName: String,
        organizationId: UUID? = nil,
        meetingSpecificContext: String? = nil
    ) {
        self.meetingName = meetingName
        self.organizationId = organizationId
        self.meetingSpecificContext = meetingSpecificContext
    }
}
