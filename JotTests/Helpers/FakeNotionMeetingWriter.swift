import Foundation
@testable import Jot

/// Test-only `NotionMeetingWriter` that records every call and lets tests
/// stub success / failure responses without standing up a `URLProtocol`
/// mock.
final class FakeNotionMeetingWriter: NotionMeetingWriter, @unchecked Sendable {

    /// One captured `createMeetingPage(...)` invocation.
    struct Call: Equatable, Sendable {
        let config: NotionConfig
        let meetingName: String
        let transcript: String
        let additionalContext: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _describeCalls: Int = 0

    /// What the next call returns. Replaced after each call so tests can
    /// queue different outcomes per meeting. Defaults to a stock success.
    nonisolated(unsafe) var nextResult: Result<NotionPageResult, NotionError> = .success(
        NotionPageResult(
            pageId: "stub-page-id",
            url: URL(string: "https://www.notion.so/Stub-page-stubpageid")!
        )
    )

    /// What `describeDatabase(...)` returns. Defaults to a basic stub.
    nonisolated(unsafe) var describeResult: Result<NotionDatabaseInfo, NotionError> = .success(
        NotionDatabaseInfo(title: "Meetings", titlePropertyName: "Name")
    )

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var describeCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _describeCalls
    }

    func createMeetingPage(
        config: NotionConfig,
        meetingName: String,
        transcript: String,
        additionalContext: String
    ) async throws -> NotionPageResult {
        lock.lock()
        _calls.append(Call(
            config: config,
            meetingName: meetingName,
            transcript: transcript,
            additionalContext: additionalContext
        ))
        lock.unlock()
        switch nextResult {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }

    func describeDatabase(config: NotionConfig) async throws -> NotionDatabaseInfo {
        lock.lock()
        _describeCalls += 1
        lock.unlock()
        switch describeResult {
        case .success(let info): return info
        case .failure(let e): throw e
        }
    }
}
