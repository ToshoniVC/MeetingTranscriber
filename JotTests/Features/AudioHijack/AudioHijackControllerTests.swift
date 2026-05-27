import Testing
import Foundation
@testable import Jot

/// Tests for `AudioHijackController.toggleRecording(...)` and
/// `stopRecordingIfActive(...)`. Both dependencies (the prompter and the
/// shortcut invoker) are injected so no actual dialog appears and no
/// `/usr/bin/shortcuts` process is spawned.
@MainActor
struct AudioHijackControllerTests {

    // MARK: - Fixtures

    private struct Fixture {
        let controller: AudioHijackController
        let prompter: StubMeetingNamePrompter
        let runner: RecordingProcessRunner
        let presence: AudioHijackPresence
    }

    private func makeFixture(
        audioHijackInstalled: Bool = true
    ) -> Fixture {
        let prompter = StubMeetingNamePrompter()
        let runner = RecordingProcessRunner()
        let invoker = ShortcutInvoker(runner: runner)
        let presence = AudioHijackPresence(
            bundleIDLookup: { _ in
                audioHijackInstalled ? URL(fileURLWithPath: "/Applications/Audio Hijack.app") : nil
            },
            pathExistsCheck: { _ in false },
            bundleIDFromURL: { _ in
                audioHijackInstalled ? "com.rogueamoeba.audiohijack" : nil
            }
        )
        let controller = AudioHijackController(
            prompter: prompter,
            invoker: invoker,
            presence: presence
        )
        return Fixture(controller: controller, prompter: prompter, runner: runner, presence: presence)
    }

    // MARK: - Toggle: start path (not currently recording)

    @Test
    func toggle_whenNotRecording_promptsAndRunsStartShortcut() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = "Standup"
        let action = try await f.controller.toggleRecording(
            isCurrentlyRecording: false,
            startShortcutName: "Jot Start Recording",
            stopShortcutName: "Jot Stop Recording"
        )
        if case .started(let name) = action {
            #expect(name == "Standup")
        } else {
            Issue.record("Expected .started, got \(action)")
        }
        #expect(f.prompter.askCount == 1)
        #expect(f.runner.calls.count == 1)
        // shortcuts run "Jot Start Recording" --input-path -
        #expect(f.runner.calls[0].arguments[0] == "run")
        #expect(f.runner.calls[0].arguments[1] == "Jot Start Recording")
        #expect(f.runner.calls[0].arguments.contains("--input-path"))
        // Meeting name was piped via stdin.
        #expect(f.runner.calls[0].stdin == "Standup")
    }

    @Test
    func toggle_whenNotRecording_emptyName_skipsStdinPiping() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = ""
        let action = try await f.controller.toggleRecording(
            isCurrentlyRecording: false,
            startShortcutName: "Jot Start Recording",
            stopShortcutName: "Jot Stop Recording"
        )
        if case .started(let name) = action {
            #expect(name == "")
        } else {
            Issue.record("Expected .started")
        }
        // Empty name → no --input-path arg, no stdin.
        #expect(!f.runner.calls[0].arguments.contains("--input-path"))
        #expect(f.runner.calls[0].stdin == nil)
    }

    // MARK: - Toggle: stop path (caller says we're recording)

    @Test
    func toggle_whenCallerSaysRecording_runsStopShortcutWithoutPrompt() async throws {
        let f = makeFixture()
        let action = try await f.controller.toggleRecording(
            isCurrentlyRecording: true,
            startShortcutName: "Jot Start Recording",
            stopShortcutName: "Jot Stop Recording"
        )
        #expect(action == .stopped)
        #expect(f.prompter.askCount == 0)
        #expect(f.runner.calls.count == 1)
        #expect(f.runner.calls[0].arguments == ["run", "Jot Stop Recording"])
        // Stop path never pipes stdin.
        #expect(f.runner.calls[0].stdin == nil)
    }

    // MARK: - Cancel

    @Test
    func toggle_whenUserCancelsPrompt_throwsUserCancelled() async {
        let f = makeFixture()
        f.prompter.nextResponse = nil
        do {
            _ = try await f.controller.toggleRecording(
                isCurrentlyRecording: false,
                startShortcutName: "Jot Start Recording",
                stopShortcutName: "Jot Stop Recording"
            )
            Issue.record("Expected throw")
        } catch let error as AudioHijackRecordingError {
            #expect(error == .userCancelled)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        // No shortcut ran — cancel happens before start.
        #expect(f.runner.calls.isEmpty)
    }

    // MARK: - Not installed

    @Test
    func toggle_whenAudioHijackNotInstalled_throws() async {
        let f = makeFixture(audioHijackInstalled: false)
        f.prompter.nextResponse = "x"
        do {
            _ = try await f.controller.toggleRecording(
                isCurrentlyRecording: false,
                startShortcutName: "Jot Start Recording",
                stopShortcutName: "Jot Stop Recording"
            )
            Issue.record("Expected throw")
        } catch let error as AudioHijackRecordingError {
            #expect(error == .audioHijackNotInstalled)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        // No shortcut runs when AH isn't installed.
        #expect(f.runner.calls.isEmpty)
        #expect(f.prompter.askCount == 0)
    }

    // MARK: - Shortcut failures

    @Test
    func toggle_shortcutNonZeroExit_throwsShortcutFailed() async {
        let f = makeFixture()
        f.prompter.nextResponse = "x"
        f.runner.nextResult = ProcessResult(exitCode: 1, stdout: "", stderr: "shortcut not found")
        do {
            _ = try await f.controller.toggleRecording(
                isCurrentlyRecording: false,
                startShortcutName: "Missing Shortcut",
                stopShortcutName: "Jot Stop Recording"
            )
            Issue.record("Expected throw")
        } catch let error as AudioHijackRecordingError {
            if case .shortcutFailed(let name, let stderr) = error {
                #expect(name == "Missing Shortcut")
                #expect(stderr.contains("not found"))
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func toggle_shortcutLaunchFailure_throwsLaunchFailed() async {
        let f = makeFixture()
        f.prompter.nextResponse = "x"
        f.runner.nextError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "couldn't spawn"
        ])
        do {
            _ = try await f.controller.toggleRecording(
                isCurrentlyRecording: false,
                startShortcutName: "Jot Start Recording",
                stopShortcutName: "Jot Stop Recording"
            )
            Issue.record("Expected throw")
        } catch let error as AudioHijackRecordingError {
            if case .launchFailed(let message) = error {
                #expect(message.contains("couldn't spawn"))
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Force-stop

    @Test
    func stopRecordingIfActive_runsStopShortcut() async throws {
        let f = makeFixture()
        try await f.controller.stopRecordingIfActive(stopShortcutName: "Jot Stop Recording")
        #expect(f.runner.calls.count == 1)
        #expect(f.runner.calls[0].arguments == ["run", "Jot Stop Recording"])
    }

    @Test
    func stopRecordingIfActive_whenAHNotInstalled_isNoOp() async throws {
        let f = makeFixture(audioHijackInstalled: false)
        try await f.controller.stopRecordingIfActive(stopShortcutName: "Jot Stop Recording")
        #expect(f.runner.calls.isEmpty)
    }

    // MARK: - Error messages

    @Test
    func userFacingMessages_areNonEmpty_andDistinctPerCase() {
        let cases: [AudioHijackRecordingError] = [
            .userCancelled,
            .audioHijackNotInstalled,
            .shortcutFailed(name: "X", stderr: "oops"),
            .launchFailed("nope"),
        ]
        var messages = Set<String>()
        for error in cases {
            #expect(!error.userFacingMessage.isEmpty, "Empty message for \(error)")
            messages.insert(error.userFacingMessage)
        }
        #expect(messages.count == cases.count, "Each error case should have a distinct user-facing message")
    }

    @Test
    func shortcutFailedMessage_mentionsShortcutName_andSuggestsAuthoringIt() {
        let message = AudioHijackRecordingError.shortcutFailed(
            name: "Jot Start Recording",
            stderr: ""
        ).userFacingMessage
        #expect(message.contains("Jot Start Recording"))
        #expect(message.contains("Shortcuts app"))
    }
}
