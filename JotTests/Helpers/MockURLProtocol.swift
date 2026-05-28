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

    /// Body bytes for each request in `requests`, captured by reading
    /// `httpBodyStream` when URLSession streamed the body and falling back
    /// to `httpBody` otherwise. Same index → same request.
    nonisolated(unsafe) private(set) static var requestBodies: [Data] = []

    static func reset() {
        responder = nil
        requests = []
        requestBodies = []
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Capture *before* invoking the responder so even thrown-from-responder
        // calls show up in `requests` for diagnostic purposes.
        Self.requests.append(request)
        Self.requestBodies.append(Self.readBody(of: request))

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

    /// Read the request body bytes — preferring `httpBody`, falling back to
    /// draining `httpBodyStream` (URLSession turns body Data into a stream
    /// before passing it to URLProtocol on most paths).
    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }

        var data = Data()
        let bufferSize = 8 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        stream.open()
        defer { stream.close() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
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
