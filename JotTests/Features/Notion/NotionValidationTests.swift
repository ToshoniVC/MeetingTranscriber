import Testing
import Foundation
@testable import Jot

/// Unit tests for `NotionValidation.validate(...)` and the
/// `NotionConfig.normalize(databaseId:)` helper. All four status branches
/// must be exercised, and the database-ID normalization must accept both
/// hyphenated and bare-hex 32-char inputs while rejecting anything else.
struct NotionValidationTests {

    // Canonical hyphenated 36-char form returned by `normalize`.
    private let canonical = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
    private let canonicalBareHex = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"

    // MARK: - .disabled

    @Test
    func validate_whenDisabled_returnsDisabled() {
        let status = NotionValidation.validate(enabled: false, token: "secret_x", databaseId: canonical)
        #expect(status == .disabled)
    }

    @Test
    func validate_whenDisabled_evenWithCompleteConfig_returnsDisabled() {
        let status = NotionValidation.validate(enabled: false, token: "secret_x", databaseId: canonical)
        #expect(status == .disabled)
    }

    // MARK: - .misconfigured

    @Test
    func validate_whenEnabledButTokenNil_returnsMisconfigured() {
        let status = NotionValidation.validate(enabled: true, token: nil, databaseId: canonical)
        if case .misconfigured(let reason) = status {
            #expect(reason.contains("token"))
        } else {
            Issue.record("Expected .misconfigured, got \(status)")
        }
    }

    @Test
    func validate_whenEnabledButTokenEmpty_returnsMisconfigured() {
        let status = NotionValidation.validate(enabled: true, token: "", databaseId: canonical)
        if case .misconfigured = status { /* ok */ } else {
            Issue.record("Expected .misconfigured, got \(status)")
        }
    }

    @Test
    func validate_whenEnabledButTokenWhitespaceOnly_returnsMisconfigured() {
        let status = NotionValidation.validate(enabled: true, token: "   \n  ", databaseId: canonical)
        if case .misconfigured(let reason) = status {
            #expect(reason.contains("token"))
        } else {
            Issue.record("Expected .misconfigured, got \(status)")
        }
    }

    @Test
    func validate_whenEnabledButDatabaseIdEmpty_returnsMisconfigured() {
        let status = NotionValidation.validate(enabled: true, token: "secret_x", databaseId: "")
        if case .misconfigured(let reason) = status {
            #expect(reason.contains("database"))
        } else {
            Issue.record("Expected .misconfigured, got \(status)")
        }
    }

    @Test
    func validate_whenEnabledButDatabaseIdMalformed_returnsMisconfigured() {
        // 30 chars of hex → too short.
        let status = NotionValidation.validate(
            enabled: true,
            token: "secret_x",
            databaseId: "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c"
        )
        if case .misconfigured(let reason) = status {
            #expect(reason.lowercased().contains("32"))
        } else {
            Issue.record("Expected .misconfigured, got \(status)")
        }
    }

    @Test
    func validate_whenEnabledButDatabaseIdHasNonHex_returnsMisconfigured() {
        let status = NotionValidation.validate(
            enabled: true,
            token: "secret_x",
            databaseId: "ZZZZ3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
        )
        if case .misconfigured = status { /* ok */ } else {
            Issue.record("Expected .misconfigured, got \(status)")
        }
    }

    // MARK: - .ready

    @Test
    func validate_withHyphenatedDatabaseId_returnsReady() {
        let status = NotionValidation.validate(
            enabled: true,
            token: "secret_abc",
            databaseId: canonical
        )
        guard case .ready(let config) = status else {
            Issue.record("Expected .ready, got \(status)")
            return
        }
        #expect(config.token == "secret_abc")
        #expect(config.databaseId == canonical)
        #expect(config.apiVersion == NotionConfig.defaultAPIVersion)
    }

    @Test
    func validate_withBareHexDatabaseId_normalizesToHyphenated() {
        let status = NotionValidation.validate(
            enabled: true,
            token: "secret_abc",
            databaseId: canonicalBareHex
        )
        guard case .ready(let config) = status else {
            Issue.record("Expected .ready, got \(status)")
            return
        }
        #expect(config.databaseId == canonical)
    }

    @Test
    func validate_trimsTokenWhitespace() {
        let status = NotionValidation.validate(
            enabled: true,
            token: "  secret_abc  \n",
            databaseId: canonical
        )
        guard case .ready(let config) = status else {
            Issue.record("Expected .ready, got \(status)")
            return
        }
        #expect(config.token == "secret_abc")
    }

    @Test
    func validate_acceptsUppercaseHexInDatabaseId() {
        let status = NotionValidation.validate(
            enabled: true,
            token: "secret_x",
            databaseId: "1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D"
        )
        guard case .ready(let config) = status else {
            Issue.record("Expected .ready, got \(status)")
            return
        }
        // Normalization downcases; this is fine for the API.
        #expect(config.databaseId == canonical)
    }
}
