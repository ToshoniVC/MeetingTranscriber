import Testing
import Foundation
@testable import Jot

/// Tests for `AudioHijackController`'s three single-purpose methods
/// (`startRecording`, `stopRecording`, `collectMetadata`) plus the
/// menu-bar-driven `stopRecordingIfActive`. Both dependencies (the
/// prompter and the shortcut invoker) are injected so no actual dialog
/// appears and no Shortcuts URL gets opened.
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

    // MARK: - startRecording

    @Test
    func startRecording_opensStartURL_andReturnsTimestamp() async throws {
        let f = makeFixture()
        let before = Date()
        let startedAt = try await f.controller.startRecording(startShortcutName: "Jot Start Recording")
        let after = Date()

        #expect(f.opener.openedURLs.count == 1)
        let url = f.opener.openedURLs[0]
        #expect(url.scheme == "shortcuts")
        #expect(url.host == "run-shortcut")
        #expect(url.queryValue(named: "name") == "Jot Start Recording")
        // No input on the start Shortcut — meeting name is collected later.
        #expect(url.queryValue(named: "input") == nil)
        // Timestamp must be captured before the user could possibly
        // dismiss the (not-yet-shown) prompt.
        #expect(startedAt >= before)
        #expect(startedAt <= after)
        // The prompt is NOT shown here — that's collectMetadata's job.
        #expect(f.prompter.askCount == 0)
    }

    @Test
    func startRecording_whenAHNotInstalled_throws() async {
        let f = makeFixture(audioHijackInstalled: false)
        do {
            _ = try await f.controller.startRecording(startShortcutName: "Jot Start Recording")
            Issue.record("Expected throw")
        } catch let error as AudioHijackRecordingError {
            #expect(error == .audioHijackNotInstalled)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(f.opener.openedURLs.isEmpty)
    }

    @Test
    func startRecording_openerFailure_throwsShortcutOpenFailed() async {
        let f = makeFixture()
        f.opener.nextError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Shortcuts unavailable"
        ])
        do {
            _ = try await f.controller.startRecording(startShortcutName: "Jot Start Recording")
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

    // MARK: - stopRecording

    @Test
    func stopRecording_opensStopURL() async throws {
        let f = makeFixture()
        try await f.controller.stopRecording(stopShortcutName: "Jot Stop Recording")
        #expect(f.opener.openedURLs.count == 1)
        let url = f.opener.openedURLs[0]
        #expect(url.queryValue(named: "name") == "Jot Stop Recording")
        #expect(url.queryValue(named: "input") == nil)
    }

    @Test
    func stopRecording_whenAHNotInstalled_throws() async {
        let f = makeFixture(audioHijackInstalled: false)
        do {
            try await f.controller.stopRecording(stopShortcutName: "Jot Stop Recording")
            Issue.record("Expected throw")
        } catch let error as AudioHijackRecordingError {
            #expect(error == .audioHijackNotInstalled)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - collectMetadata

    @Test
    func collectMetadata_returnsInputs_andDoesNotTouchAH() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = MeetingStartInputs(meetingName: "Standup")
        let result = await f.controller.collectMetadata(
            organizations: [],
            defaultOrgId: nil
        )
        #expect(result?.meetingName == "Standup")
        #expect(f.prompter.askCount == 1)
        // No AH side-effects — recording was already running before
        // metadata collection began.
        #expect(f.opener.openedURLs.isEmpty)
    }

    @Test
    func collectMetadata_userCancel_returnsNil() async {
        let f = makeFixture()
        f.prompter.nextResponse = nil
        let result = await f.controller.collectMetadata(
            organizations: [],
            defaultOrgId: nil
        )
        #expect(result == nil)
    }

    @Test
    func collectMetadata_passesOrgsAndDefaultThrough() async {
        let f = makeFixture()
        let acme = Organization(name: "Acme", isDefault: true)
        f.prompter.nextResponse = MeetingStartInputs(
            meetingName: "Standup",
            organizationId: acme.id,
            meetingSpecificContext: "Notes"
        )
        _ = await f.controller.collectMetadata(
            organizations: [acme],
            defaultOrgId: acme.id
        )
        #expect(f.prompter.lastOrganizations.map(\.id) == [acme.id])
        #expect(f.prompter.lastDefaultOrgId == acme.id)
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
