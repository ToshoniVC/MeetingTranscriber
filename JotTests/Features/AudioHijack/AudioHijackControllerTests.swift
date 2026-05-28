import Testing
import Foundation
@testable import Jot

/// Tests for `AudioHijackController.toggleRecording(...)` and
/// `stopRecordingIfActive(...)`. Both dependencies (the prompter and the
/// shortcut invoker) are injected so no actual dialog appears and no
/// Shortcuts URL gets opened.
@MainActor
struct AudioHijackControllerTests {

    // MARK: - Fixtures

    private struct Fixture {
        let controller: AudioHijackController
        let prompter: StubMeetingStartPrompter
        let opener: RecordingURLOpener
        let presence: AudioHijackPresence
    }

    private func makeFixture(
        audioHijackInstalled: Bool = true
    ) -> Fixture {
        let prompter = StubMeetingStartPrompter()
        let opener = RecordingURLOpener()
        let invoker = ShortcutInvoker(opener: opener)
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
        return Fixture(controller: controller, prompter: prompter, opener: opener, presence: presence)
    }

    private func toggle(
        _ controller: AudioHijackController,
        isCurrentlyRecording: Bool = false,
        organizations: [Organization] = [],
        defaultOrgId: UUID? = nil
    ) async throws -> RecordingAction {
        try await controller.toggleRecording(
            isCurrentlyRecording: isCurrentlyRecording,
            startShortcutName: "Jot Start Recording",
            stopShortcutName: "Jot Stop Recording",
            organizations: organizations,
            defaultOrgId: defaultOrgId
        )
    }

    // MARK: - Toggle: start path (not currently recording)

    @Test
    func toggle_whenNotRecording_promptsAndOpensStartURL() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = MeetingStartInputs(meetingName: "Standup")
        let action = try await toggle(f.controller)
        if case .started(let inputs) = action {
            #expect(inputs.meetingName == "Standup")
        } else {
            Issue.record("Expected .started, got \(action)")
        }
        #expect(f.prompter.askCount == 1)
        #expect(f.opener.openedURLs.count == 1)
        let url = f.opener.openedURLs[0]
        #expect(url.scheme == "shortcuts")
        #expect(url.host == "run-shortcut")
        #expect(url.queryValue(named: "name") == "Jot Start Recording")
        #expect(url.queryValue(named: "input") == "Standup")
    }

    @Test
    func toggle_whenNotRecording_emptyName_omitsInputParam() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = MeetingStartInputs(meetingName: "")
        let action = try await toggle(f.controller)
        if case .started(let inputs) = action {
            #expect(inputs.meetingName == "")
        } else {
            Issue.record("Expected .started")
        }
        let url = f.opener.openedURLs[0]
        #expect(url.queryValue(named: "input") == nil)
    }

    @Test
    func toggle_passesOrgsAndDefaultThrough() async throws {
        let f = makeFixture()
        let acme = Organization(name: "Acme", isDefault: true)
        f.prompter.nextResponse = MeetingStartInputs(
            meetingName: "Standup",
            organizationId: acme.id,
            meetingSpecificContext: "Notes"
        )
        let action = try await toggle(
            f.controller,
            organizations: [acme],
            defaultOrgId: acme.id
        )
        #expect(f.prompter.lastOrganizations.map(\.id) == [acme.id])
        #expect(f.prompter.lastDefaultOrgId == acme.id)
        if case .started(let inputs) = action {
            #expect(inputs.organizationId == acme.id)
            #expect(inputs.meetingSpecificContext == "Notes")
        } else {
            Issue.record("Expected .started")
        }
    }

    // MARK: - Toggle: stop path (caller says we're recording)

    @Test
    func toggle_whenCallerSaysRecording_opensStopURL_withoutPrompt() async throws {
        let f = makeFixture()
        let action = try await toggle(f.controller, isCurrentlyRecording: true)
        #expect(action == .stopped)
        #expect(f.prompter.askCount == 0)
        #expect(f.opener.openedURLs.count == 1)
        let url = f.opener.openedURLs[0]
        #expect(url.queryValue(named: "name") == "Jot Stop Recording")
        #expect(url.queryValue(named: "input") == nil)
    }

    // MARK: - Cancel

    @Test
    func toggle_whenUserCancelsPrompt_throwsUserCancelled() async {
        let f = makeFixture()
        f.prompter.nextResponse = nil
        do {
            _ = try await toggle(f.controller)
            Issue.record("Expected throw")
        } catch let error as AudioHijackRecordingError {
            #expect(error == .userCancelled)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(f.opener.openedURLs.isEmpty)
    }

    // MARK: - Not installed

    @Test
    func toggle_whenAudioHijackNotInstalled_throws() async {
        let f = makeFixture(audioHijackInstalled: false)
        f.prompter.nextResponse = MeetingStartInputs(meetingName: "x")
        do {
            _ = try await toggle(f.controller)
            Issue.record("Expected throw")
        } catch let error as AudioHijackRecordingError {
            #expect(error == .audioHijackNotInstalled)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(f.opener.openedURLs.isEmpty)
        #expect(f.prompter.askCount == 0)
    }

    // MARK: - URL-open failures

    @Test
    func toggle_openerFailure_throwsShortcutOpenFailed() async {
        let f = makeFixture()
        f.prompter.nextResponse = MeetingStartInputs(meetingName: "x")
        f.opener.nextError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Shortcuts unavailable"
        ])
        do {
            _ = try await toggle(f.controller)
            Issue.record("Expected throw")
        } catch let error as AudioHijackRecordingError {
            if case .shortcutOpenFailed(let name, let detail) = error {
                #expect(name == "Jot Start Recording")
                #expect(detail.contains("unavailable"))
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Force-stop

    @Test
    func stopRecordingIfActive_opensStopURL() async throws {
        let f = makeFixture()
        try await f.controller.stopRecordingIfActive(stopShortcutName: "Jot Stop Recording")
        #expect(f.opener.openedURLs.count == 1)
        #expect(f.opener.openedURLs[0].queryValue(named: "name") == "Jot Stop Recording")
    }

    @Test
    func stopRecordingIfActive_whenAHNotInstalled_isNoOp() async throws {
        let f = makeFixture(audioHijackInstalled: false)
        try await f.controller.stopRecordingIfActive(stopShortcutName: "Jot Stop Recording")
        #expect(f.opener.openedURLs.isEmpty)
    }

    // MARK: - Error messages

    @Test
    func userFacingMessages_areNonEmpty_andDistinctPerCase() {
        let cases: [AudioHijackRecordingError] = [
            .userCancelled,
            .audioHijackNotInstalled,
            .shortcutOpenFailed(name: "X", detail: "oops"),
        ]
        var messages = Set<String>()
        for error in cases {
            #expect(!error.userFacingMessage.isEmpty, "Empty message for \(error)")
            messages.insert(error.userFacingMessage)
        }
        #expect(messages.count == cases.count, "Each error case should have a distinct user-facing message")
    }

    @Test
    func shortcutOpenFailedMessage_mentionsShortcutName_andSuggestsShortcutsApp() {
        let message = AudioHijackRecordingError.shortcutOpenFailed(
            name: "Jot Start Recording",
            detail: ""
        ).userFacingMessage
        #expect(message.contains("Jot Start Recording"))
        #expect(message.contains("Shortcuts app"))
    }
}

/// Convenience for assertion readability in this file.
private extension URL {
    func queryValue(named name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
