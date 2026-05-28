import Foundation
@testable import Jot

/// Test fake for `URLOpening`. Records every URL we'd ask macOS to open
/// and (optionally) throws on the next call to simulate a failure.
final class RecordingURLOpener: URLOpening, @unchecked Sendable {
    private(set) var openedURLs: [URL] = []

    /// If non-nil, the next `open(_:)` throws this instead of recording
    /// success. Cleared after one use so subsequent calls record normally.
    var nextError: Error?

    func open(_ url: URL) async throws {
        openedURLs.append(url)
        if let nextError {
            self.nextError = nil
            throw nextError
        }
    }
}
