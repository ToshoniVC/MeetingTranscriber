import Foundation

/// Per-task `URLSessionTaskDelegate` that captures which application
/// protocol URLSession negotiated for a request (`h3`, `h2`, `http/1.1`) so
/// the HTTP clients can log it. Added in v0.7.3 alongside
/// `HTTPSessionPolicy`: if a future OS ignores the HTTP/3 opt-out, a
/// "negotiated h3" line in Console is the first place that shows.
///
/// Attach one recorder per task via
/// `session.upload(for:fromFile:delegate:)` or `session.data(for:delegate:)`.
/// URLSession delivers `didFinishCollecting` before the task completes, so
/// reading `summary` after the `await` returns (or throws) is safe.
final class NegotiatedProtocolRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [String] = []

    /// Protocol name per transaction, in order (a redirect produces more
    /// than one). Empty until metrics arrive; entries may be empty strings
    /// when URLSession reports no name (e.g. a `URLProtocol`-mocked load).
    var protocols: [String] {
        lock.withLock { recorded }
    }

    /// Console-friendly rendering: `"h2"`, `"h3, h2"`, or `"unknown"` when
    /// nothing named was collected.
    var summary: String {
        Self.summarize(protocols)
    }

    /// `true` when any transaction of the task ran over HTTP/3.
    var usedHTTP3: Bool {
        Self.usesHTTP3(protocols)
    }

    /// Pure formatting helper behind `summary`, exposed for unit tests.
    static func summarize(_ protocols: [String]) -> String {
        let named = protocols.filter { !$0.isEmpty }
        return named.isEmpty ? "unknown" : named.joined(separator: ", ")
    }

    /// Pure helper behind `usedHTTP3`, exposed for unit tests.
    static func usesHTTP3(_ protocols: [String]) -> Bool {
        protocols.contains { $0.lowercased() == "h3" }
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let names = metrics.transactionMetrics.map { $0.networkProtocolName ?? "" }
        lock.withLock { recorded = names }
    }
}
