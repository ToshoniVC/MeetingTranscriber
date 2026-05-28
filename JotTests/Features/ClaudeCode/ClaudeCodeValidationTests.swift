import Testing
import Foundation
@testable import Jot

/// Branch coverage for `ClaudeCodeValidation`. Mirrors
/// `NotionValidationTests` in shape.
struct ClaudeCodeValidationTests {

    private let endpoint = "https://api.anthropic.com/v1/claude_code/routines/trg_abc/fire"
    private let token = "anthropic-bearer-token"

    // MARK: - disabled

    @Test
    func disabled_whenToggleOff_regardlessOfOtherFields() {
        let result = ClaudeCodeValidation.validate(
            enabled: false,
            endpoint: endpoint,
            token: token,
            extraText: "extra"
        )
        #expect(result == .disabled)
    }

    // MARK: - misconfigured

    @Test
    func misconfigured_whenEndpointEmpty() {
        let result = ClaudeCodeValidation.validate(
            enabled: true,
            endpoint: "",
            token: token,
            extraText: ""
        )
        guard case .misconfigured(let reason) = result else {
            Issue.record("Expected .misconfigured, got \(result)")
            return
        }
        #expect(reason.lowercased().contains("endpoint"))
    }

    @Test
    func misconfigured_whenEndpointWhitespace() {
        let result = ClaudeCodeValidation.validate(
            enabled: true,
            endpoint: "   \n  ",
            token: token,
            extraText: ""
        )
        if case .misconfigured = result { } else {
            Issue.record("Expected .misconfigured, got \(result)")
        }
    }

    @Test
    func misconfigured_whenEndpointMalformed() {
        // Missing scheme.
        let result = ClaudeCodeValidation.validate(
            enabled: true,
            endpoint: "api.anthropic.com/foo",
            token: token,
            extraText: ""
        )
        if case .misconfigured = result { } else {
            Issue.record("Expected .misconfigured for missing scheme, got \(result)")
        }
    }

    @Test
    func misconfigured_whenEndpointSchemeUnsupported() {
        let result = ClaudeCodeValidation.validate(
            enabled: true,
            endpoint: "ftp://api.anthropic.com/foo",
            token: token,
            extraText: ""
        )
        if case .misconfigured = result { } else {
            Issue.record("Expected .misconfigured for non-http scheme, got \(result)")
        }
    }

    @Test
    func misconfigured_whenTokenMissing() {
        let result = ClaudeCodeValidation.validate(
            enabled: true,
            endpoint: endpoint,
            token: nil,
            extraText: ""
        )
        guard case .misconfigured(let reason) = result else {
            Issue.record("Expected .misconfigured, got \(result)")
            return
        }
        #expect(reason.lowercased().contains("token"))
    }

    @Test
    func misconfigured_whenTokenWhitespace() {
        let result = ClaudeCodeValidation.validate(
            enabled: true,
            endpoint: endpoint,
            token: "   ",
            extraText: ""
        )
        if case .misconfigured = result { } else {
            Issue.record("Expected .misconfigured, got \(result)")
        }
    }

    // MARK: - ready

    @Test
    func ready_withMinimalValidInputs() {
        let result = ClaudeCodeValidation.validate(
            enabled: true,
            endpoint: endpoint,
            token: token,
            extraText: ""
        )
        guard case .ready(let config) = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
        #expect(config.endpoint.absoluteString == endpoint)
        #expect(config.token == token)
        #expect(config.extraText == "")
    }

    @Test
    func ready_preservesExtraTextVerbatim() {
        let result = ClaudeCodeValidation.validate(
            enabled: true,
            endpoint: endpoint,
            token: token,
            extraText: "  please be detailed.  "
        )
        guard case .ready(let config) = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
        // We do NOT trim extraText — the user may have intentional
        // padding/newlines they want inside the routine session.
        #expect(config.extraText == "  please be detailed.  ")
    }

    @Test
    func ready_trimsTokenAndEndpoint() {
        let result = ClaudeCodeValidation.validate(
            enabled: true,
            endpoint: "  \(endpoint)  ",
            token: "  \(token)  ",
            extraText: ""
        )
        guard case .ready(let config) = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
        #expect(config.endpoint.absoluteString == endpoint)
        #expect(config.token == token)
    }
}
