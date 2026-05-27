import Foundation
@testable import Jot

/// Test fake for `ProcessRunner`. Records every `run(...)` call's argv and
/// returns whatever `nextResult` is set to (or throws `nextError`).
final class RecordingProcessRunner: ProcessRunner, @unchecked Sendable {

    struct Call: Equatable, Sendable {
        let executable: URL
        let arguments: [String]
        let stdin: String?
    }

    private(set) var calls: [Call] = []

    /// Result returned by the next call. Defaults to exit 0, empty stdout/stderr.
    var nextResult: ProcessResult = ProcessResult(exitCode: 0, stdout: "", stderr: "")

    /// If non-nil, the next `run(...)` throws this instead of returning.
    var nextError: Error?

    func run(executable: URL, arguments: [String], stdin: String?) async throws -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments, stdin: stdin))
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        return nextResult
    }
}
