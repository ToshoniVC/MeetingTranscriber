import Testing
import Foundation
@testable import Jot

/// Codable round-trip for `MeetingContextSnapshot`.
struct MeetingContextSnapshotTests {

    @Test
    func roundTrip_preservesAllFields() throws {
        let original = MeetingContextSnapshot(
            meetingName: "Roadmap Sync",
            organizationId: UUID(),
            meetingSpecificContext: "Focus on Q3.",
            resolvedCompiledContext: "Compiled body",
            lastEditedAt: Date()
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingContextSnapshot.self, from: data)
        #expect(decoded.meetingName == original.meetingName)
        #expect(decoded.organizationId == original.organizationId)
        #expect(decoded.meetingSpecificContext == original.meetingSpecificContext)
        #expect(decoded.resolvedCompiledContext == original.resolvedCompiledContext)
        #expect(decoded.schemaVersion == 1)
    }

    @Test
    func roundTrip_noOrgNoContext_minimumPayload() throws {
        let original = MeetingContextSnapshot(meetingName: "Lone Sync")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingContextSnapshot.self, from: data)
        #expect(decoded.meetingName == "Lone Sync")
        #expect(decoded.organizationId == nil)
        #expect(decoded.meetingSpecificContext == nil)
        #expect(decoded.resolvedCompiledContext == "")
    }

    @Test
    func roundTrip_preservesLanguageCode() throws {
        let original = MeetingContextSnapshot(meetingName: "Sync", languageCode: "nl")
        let decoded = try JSONDecoder().decode(MeetingContextSnapshot.self, from: try JSONEncoder().encode(original))
        #expect(decoded.languageCode == "nl")
    }

    @Test
    func decode_legacyPayloadWithoutLanguage_yieldsNil() throws {
        let json = #"{"meetingName":"Old","resolvedCompiledContext":"","lastEditedAt":0,"schemaVersion":1}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MeetingContextSnapshot.self, from: json)
        #expect(decoded.languageCode == nil)
        #expect(decoded.meetingName == "Old")
    }
}
