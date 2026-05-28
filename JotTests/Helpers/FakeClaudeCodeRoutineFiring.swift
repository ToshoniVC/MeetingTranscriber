import Foundation
@testable import Jot

/// Test-only `ClaudeCodeRoutineFiring` that records every call and lets
/// tests stub success / failure responses without standing up a
/// `URLProtocol` mock. Mirrors `FakeNotionMeetingWriter`'s shape.
final class FakeClaudeCodeRoutineFiring: ClaudeCodeRoutineFiring, @unchecked Sendable {

    /// One captured `fire(...)` invocation.
    struct Call: Equatable, Sendable {
        let config: ClaudeCodeRoutineConfig
        let text: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []

    /// What the next call returns. Defaults to a stock success.
    nonisolated(unsafe) var nextResult: Result<Void, ClaudeCodeRoutineError> = .success(())

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func fire(config: ClaudeCodeRoutineConfig, text: String) async throws {
        lock.lock()
        _calls.append(Call(config: config, text: text))
        lock.unlock()
        switch nextResult {
        case .success: return
        case .failure(let e): throw e
        }
    }
}
