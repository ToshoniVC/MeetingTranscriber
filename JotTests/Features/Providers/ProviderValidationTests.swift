import Testing
import Foundation
@testable import Jot

/// Unit tests for `ProviderValidation`. Pure functions — no I/O.
struct ProviderValidationTests {

    private static func valid() -> Provider {
        Provider(
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1/audio/transcriptions",
            model: "whisper-1"
        )
    }

    // MARK: - validate(...)

    @Test
    func validate_happyPath_doesNotThrow() throws {
        try ProviderValidation.validate(Self.valid(), against: [])
    }

    @Test
    func validate_emptyDisplayName_throws() {
        var p = Self.valid()
        p.displayName = "   "
        #expect(throws: ProviderValidationError.displayNameEmpty) {
            try ProviderValidation.validate(p, against: [])
        }
    }

    @Test
    func validate_duplicateDisplayName_throwsCaseInsensitive() {
        let existing = Provider(displayName: "OpenAI", baseURL: "https://x/y", model: "m")
        var p = Self.valid()
        p.displayName = "openai" // different case
        do {
            try ProviderValidation.validate(p, against: [existing])
            Issue.record("Expected throw")
        } catch ProviderValidationError.displayNameDuplicate(let name) {
            #expect(name == "openai")
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test
    func validate_sameIdSameName_doesNotThrow() throws {
        // Editing an existing provider keeps the same id — the duplicate
        // check excludes the row being edited so re-saving without
        // renaming is fine.
        let p = Self.valid()
        try ProviderValidation.validate(p, against: [p])
    }

    @Test
    func validate_emptyBaseURL_throws() {
        var p = Self.valid()
        p.baseURL = ""
        #expect(throws: ProviderValidationError.baseURLEmpty) {
            try ProviderValidation.validate(p, against: [])
        }
    }

    @Test
    func validate_baseURLWithoutScheme_throws() {
        var p = Self.valid()
        p.baseURL = "api.openai.com/v1"
        do {
            try ProviderValidation.validate(p, against: [])
            Issue.record("Expected throw")
        } catch ProviderValidationError.baseURLInvalid {
            // ok
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test
    func validate_emptyModel_throws() {
        var p = Self.valid()
        p.model = ""
        #expect(throws: ProviderValidationError.modelEmpty) {
            try ProviderValidation.validate(p, against: [])
        }
    }

    // MARK: - readiness(of:)

    @Test
    func readiness_disabled_returnsDisabled() {
        var p = Self.valid()
        p.isEnabled = false
        let r = ProviderValidation.readiness(of: p) { _ in true }
        #expect(r == .disabled)
    }

    @Test
    func readiness_incomplete_returnsIncomplete() {
        var p = Self.valid()
        p.model = ""
        let r = ProviderValidation.readiness(of: p) { _ in true }
        #expect(r == .incomplete)
    }

    @Test
    func readiness_missingKey_returnsMissingKey() {
        let p = Self.valid()
        let r = ProviderValidation.readiness(of: p) { _ in false }
        #expect(r == .missingKey)
    }

    @Test
    func readiness_validAndKeyed_returnsReady() {
        let p = Self.valid()
        let r = ProviderValidation.readiness(of: p) { _ in true }
        #expect(r == .ready)
    }
}
