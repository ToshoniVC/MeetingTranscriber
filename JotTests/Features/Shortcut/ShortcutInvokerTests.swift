import Testing
import Foundation
@testable import Jot

/// Tests for `ShortcutInvoker` using `RecordingProcessRunner` so no real
/// `shortcuts` CLI gets invoked.
struct ShortcutInvokerTests {

    @Test
    func run_invokesShortcutsCLI_withRunNameArgs() async throws {
        let runner = RecordingProcessRunner()
        let invoker = ShortcutInvoker(runner: runner)
        try await invoker.run(shortcutName: "Jot Start Recording")
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.executable.path(percentEncoded: false) == "/usr/bin/shortcuts")
        #expect(runner.calls.first?.arguments == ["run", "Jot Start Recording"])
    }

    @Test
    func run_quotesArgumentsCorrectly_evenWithSpaces() async throws {
        let runner = RecordingProcessRunner()
        let invoker = ShortcutInvoker(runner: runner)
        try await invoker.run(shortcutName: "Some Shortcut With Spaces")
        // Process(arguments:) takes [String] which handles spaces natively —
        // we just pass them through. Verify the arg is unmangled.
        #expect(runner.calls.first?.arguments == ["run", "Some Shortcut With Spaces"])
    }

    @Test
    func run_executableOverride_isUsed() async throws {
        let runner = RecordingProcessRunner()
        let custom = URL(fileURLWithPath: "/usr/local/bin/shortcuts")
        let invoker = ShortcutInvoker(executable: custom, runner: runner)
        try await invoker.run(shortcutName: "X")
        #expect(runner.calls.first?.executable == custom)
    }

    @Test
    func run_nonZeroExit_throwsNonZeroExit() async {
        let runner = RecordingProcessRunner()
        runner.nextResult = ProcessResult(exitCode: 2, stdout: "", stderr: "shortcut not found")
        let invoker = ShortcutInvoker(runner: runner)
        do {
            try await invoker.run(shortcutName: "missing")
            Issue.record("Expected throw")
        } catch let error as ShortcutError {
            if case .nonZeroExit(let code, let stderr) = error {
                #expect(code == 2)
                #expect(stderr.contains("not found"))
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func run_launchFailure_throwsLaunchFailed() async {
        let runner = RecordingProcessRunner()
        runner.nextError = NSError(domain: "test", code: 99, userInfo: [
            NSLocalizedDescriptionKey: "couldn't launch"
        ])
        let invoker = ShortcutInvoker(runner: runner)
        do {
            try await invoker.run(shortcutName: "x")
            Issue.record("Expected throw")
        } catch let error as ShortcutError {
            if case .launchFailed(let message) = error {
                #expect(message.contains("couldn't launch"))
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func userFacingMessages_areNonEmpty() {
        let cases: [ShortcutError] = [
            .nonZeroExit(code: 1, stderr: ""),
            .nonZeroExit(code: 2, stderr: "boom"),
            .launchFailed("nope"),
        ]
        for error in cases {
            #expect(!error.userFacingMessage.isEmpty)
        }
    }
}
