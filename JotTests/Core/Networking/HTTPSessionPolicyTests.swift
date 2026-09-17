import Testing
import Foundation
@testable import Jot

/// Unit tests for `HTTPSessionPolicy` — the HTTP/3 opt-out every Jot HTTP
/// client's session goes through (v0.7.3).
///
/// The opt-out rides on a private `URLSessionConfiguration` property, so
/// the exact-behaviour cases are gated on `http3OptOutAvailable`: on an OS
/// that exposes it we pin that the flag is set and reads back as disabled;
/// on one that doesn't we pin the graceful degradation (nothing crashes,
/// `disableHTTP3` reports `false`, `isHTTP3Disabled` reports `nil`).
struct HTTPSessionPolicyTests {

    @Test
    func disableHTTP3_reportsWhetherTheOptOutWasApplied() {
        let configuration = URLSessionConfiguration.ephemeral
        let applied = HTTPSessionPolicy.disableHTTP3(on: configuration)
        #expect(applied == HTTPSessionPolicy.http3OptOutAvailable)
    }

    @Test(.enabled(if: HTTPSessionPolicy.http3OptOutAvailable))
    func disableHTTP3_whenAvailable_flipsAFreshConfigurationFromAllowedToDisabled() {
        let configuration = URLSessionConfiguration.default
        #expect(
            HTTPSessionPolicy.isHTTP3Disabled(on: configuration) == false,
            "a fresh configuration should still allow HTTP/3"
        )
        HTTPSessionPolicy.disableHTTP3(on: configuration)
        #expect(HTTPSessionPolicy.isHTTP3Disabled(on: configuration) == true)
    }

    @Test(.enabled(if: HTTPSessionPolicy.http3OptOutAvailable))
    func disableHTTP3_isIdempotent() {
        let configuration = URLSessionConfiguration.ephemeral
        #expect(HTTPSessionPolicy.disableHTTP3(on: configuration))
        #expect(HTTPSessionPolicy.disableHTTP3(on: configuration))
        #expect(HTTPSessionPolicy.isHTTP3Disabled(on: configuration) == true)
    }

    @Test(.enabled(if: !HTTPSessionPolicy.http3OptOutAvailable))
    func disableHTTP3_whenUnavailable_isANoOpThatReportsFalse() {
        let configuration = URLSessionConfiguration.ephemeral
        #expect(!HTTPSessionPolicy.disableHTTP3(on: configuration))
        #expect(HTTPSessionPolicy.isHTTP3Disabled(on: configuration) == nil)
    }

    @Test
    func makeSession_appliesTheOptOutToTheSessionsConfiguration() {
        let session = HTTPSessionPolicy.makeSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let expected: Bool? = HTTPSessionPolicy.http3OptOutAvailable ? true : nil
        #expect(HTTPSessionPolicy.isHTTP3Disabled(on: session.configuration) == expected)
    }

    @Test
    func makeSession_preservesTheCallersConfigurationChoices() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 123
        configuration.httpAdditionalHeaders = ["X-Jot-Test": "1"]
        let session = HTTPSessionPolicy.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        #expect(session.configuration.timeoutIntervalForRequest == 123)
        #expect(session.configuration.httpAdditionalHeaders?["X-Jot-Test"] as? String == "1")
    }

    @Test
    func shared_isBuiltOnceAndReused() {
        #expect(HTTPSessionPolicy.shared === HTTPSessionPolicy.shared)
    }
}
