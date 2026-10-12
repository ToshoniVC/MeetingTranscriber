import Testing
import Foundation
@testable import Jot

/// Unit tests for `TranscriptionLanguage` resolution across the meeting /
/// organization / app-wide levels.
struct TranscriptionLanguageTests {

    @Test
    func resolve_meetingWinsOverOrganizationAndGeneral() {
        #expect(TranscriptionLanguage.resolve(meeting: "en", organization: "nl", general: "nl") == "en")
    }

    @Test
    func resolve_organizationWinsOverGeneralWhenMeetingInherits() {
        #expect(TranscriptionLanguage.resolve(meeting: nil, organization: "fr", general: "nl") == "fr")
    }

    @Test
    func resolve_fallsThroughToGeneral() {
        #expect(TranscriptionLanguage.resolve(meeting: nil, organization: nil, general: "nl") == "nl")
        #expect(TranscriptionLanguage.resolve(meeting: "", organization: "  ", general: "nl") == "nl")
    }

    @Test
    func resolve_autoDetectSentinelStopsTheWalkAndSendsNothing() {
        #expect(TranscriptionLanguage.resolve(meeting: "auto", organization: "nl", general: "nl") == nil)
        #expect(TranscriptionLanguage.resolve(meeting: nil, organization: "auto", general: "nl") == nil)
        #expect(TranscriptionLanguage.resolve(meeting: nil, organization: nil, general: "auto") == nil)
    }

    @Test
    func resolve_allEmpty_isAutoDetect() {
        #expect(TranscriptionLanguage.resolve(meeting: nil, organization: nil, general: nil) == nil)
        #expect(TranscriptionLanguage.resolve(meeting: nil, organization: nil, general: "") == nil)
    }

    @Test
    func normalized_trimsLowercasesAndNilsEmpty() {
        #expect(TranscriptionLanguage.normalized(" NL ") == "nl")
        #expect(TranscriptionLanguage.normalized("") == nil)
        #expect(TranscriptionLanguage.normalized(nil) == nil)
        #expect(TranscriptionLanguage.normalized("auto") == TranscriptionLanguage.autoDetectCode)
    }

    @Test
    func displayName_autoAndEmptyReadAsAutoDetect() {
        #expect(TranscriptionLanguage.displayName(for: "") == "Auto-detect")
        #expect(TranscriptionLanguage.displayName(for: "auto") == "Auto-detect")
    }

    @Test
    func displayName_unknownCodeFallsBackToCode() {
        #expect(TranscriptionLanguage.displayName(for: "zz-notalanguage") == "zz-notalanguage")
    }

    @Test
    func pickerCodes_leadWithDutchAndEnglish() {
        #expect(TranscriptionLanguage.pickerCodes.prefix(2) == ["nl", "en"])
    }

    @Test
    func generalContext_shipsWithDutchDefault() {
        #expect(GeneralContext().defaultLanguageCode == "nl")
        #expect(GeneralContext.defaultLanguageCode == "nl")
    }
}
