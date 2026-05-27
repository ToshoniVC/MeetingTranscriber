import Foundation

/// `URLProtocol` subclass that lets tests stand up a `URLSession` returning
/// canned responses with zero network traffic. Used by
/// `TranscriptionClientIntegrationTests` and any future tests that exercise
/// HTTP behavior.
///
/// Usage:
/// ```swift
/// MockURLProtocol.responder = { request in
///     (HTTPURLResponse(...), Data("ok".utf8), nil)   // or pass error
/// }
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [MockURLProtocol.self]
/// let session = URLSession(configuration: config)
/// ```
final class MockURLProtocol: URLProtocol {

    /// Tuple of `(response, body, error)`. If `error` is non-nil it's surfaced
    /// to the client and the response/body are ignored.
    typealias Responder = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    /// Set by tests. Reset to `nil` between cases via `reset()`.
    nonisolated(unsafe) static var responder: Responder?

    /// Records every request that flowed through this protocol, in order.
    /// Tests inspect this to verify headers, body location, etc.
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []

    static func reset() {
        responder = nil
        requests = []
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Capture *before* invoking the responder so even thrown-from-responder
        // calls show up in `requests` for diagnostic purposes.
        Self.requests.append(request)

        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, body) = try responder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op — `startLoading` completes synchronously.
    }
}

/// Convenience to build a `URLSession` wired to `MockURLProtocol`.
enum MockURLSession {
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
