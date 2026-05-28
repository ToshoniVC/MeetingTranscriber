import Testing
import Foundation
import AppKit
@testable import Jot

/// Tests for `HotkeyCoordinator` — applies the current hotkey, surfaces
/// errors, fires the shortcut when triggered.
///
/// Uses `FakeHotkeyRegistrar` + `RecordingURLOpener` so no global
/// Carbon hotkey is registered and no `/usr/bin/shortcuts` is spawned.
@MainActor
struct HotkeyCoordinatorTests {

    private func makeFixture(
        registrar: FakeHotkeyRegistrar? = nil,
        opener: RecordingURLOpener? = nil,
        prompter: StubMeetingStartPrompter? = nil,
        audioHijackInstalled: Bool = true
    ) -> (
        coordinator: HotkeyCoordinator,
        settings: AppSettings,
        registrar: FakeHotkeyRegistrar,
        opener: RecordingURLOpener,
        prompter: StubMeetingStartPrompter,
        menuBar: MenuBarController,
        auditLog: AuditLogStore,
        organizations: OrganizationStore,
        meetingContextStore: MeetingContextStore
    ) {
        let registrar = registrar ?? FakeHotkeyRegistrar()
        let opener = opener ?? RecordingURLOpener()
        let prompter = prompter ?? StubMeetingStartPrompter()
        let defaults = EphemeralUserDefaults.make()
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let auditLog = AuditLogStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("jot-hotkey-coord-\(UUID().uuidString).json")
        )
        let organizations = OrganizationStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("jot-hotkey-orgs-\(UUID().uuidString).json")
        )
        let meetingContextStore = MeetingContextStore()
        let presence = AudioHijackPresence(
            bundleIDLookup: { _ in
                audioHijackInstalled ? URL(fileURLWithPath: "/Applications/Audio Hijack.app") : nil
            },
            pathExistsCheck: { _ in false },
            bundleIDFromURL: { _ in
                audioHijackInstalled ? "com.rogueamoeba.audiohijack" : nil
            }
        )
        let invoker = ShortcutInvoker(opener: opener)
        let audioHijack = AudioHijackController(
            prompter: prompter,
            invoker: invoker,
            presence: presence
        )
        let menuBar = MenuBarController()
        let coordinator = HotkeyCoordinator(
            settings: settings,
            registrar: registrar,
            invoker: invoker,
            audioHijack: audioHijack,
            menuBar: menuBar,
            auditLog: auditLog,
            organizations: organizations,
            meetingContextStore: meetingContextStore
        )
        return (
            coordinator, settings, registrar, opener, prompter, menuBar,
            auditLog, organizations, meetingContextStore
        )
    }

    private func inputs(_ name: String) -> MeetingStartInputs {
        MeetingStartInputs(meetingName: name)
    }

    // MARK: - Registration

    @Test
    func bootstrap_withHotkey_registersIt() async {
        let f = makeFixture()
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command, .shift])
        await f.coordinator.bootstrap()
        #expect(f.registrar.registerCallCount == 1)
        #expect(f.registrar.registeredCombo?.keyCode == 15)
        #expect(f.coordinator.registrationError == nil)
        #expect(f.coordinator.activeHotkey == f.settings.recordingHotkey)
    }

    @Test
    func bootstrap_withoutHotkey_doesNotRegister() async {
        let f = makeFixture()
        await f.coordinator.bootstrap()
        #expect(f.registrar.registerCallCount == 0)
        #expect(f.coordinator.activeHotkey == nil)
    }

    @Test
    func registration_failure_surfacesError() async {
        let registrar = FakeHotkeyRegistrar()
        registrar.nextRegisterError = HotkeyError.registrationFailed(osStatus: -9878)
        let f = makeFixture(registrar: registrar)
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()
        #expect(f.coordinator.registrationError != nil)
        #expect(f.coordinator.activeHotkey == nil)
        #expect(f.coordinator.registrationError?.contains("already in use") == true)
    }

    // MARK: - Trigger → built-in Audio Hijack (default)

    @Test
    func firingHotkey_default_opensStartShortcutURL_beforePrompt() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = inputs("Standup")
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.prompter.askCount == 1)
        #expect(f.opener.openedURLs.count == 1)
        let url = f.opener.openedURLs[0]
        #expect(url.scheme == "shortcuts")
        #expect(url.host == "run-shortcut")
        #expect(url.queryValue(named: "name") == f.settings.startShortcutName)
        // v0.4.1: recording starts immediately, meeting name is collected
        // afterwards — so the start Shortcut no longer receives it on stdin.
        // The pipeline's downstream rename handles filename → meeting name.
        #expect(url.queryValue(named: "input") == nil)
    }

    @Test
    func firingHotkey_marksMenuBarRecordingBeforePromptIsAnswered() async throws {
        let f = makeFixture()
        // Stub: simulate a slow prompt by holding the response in a way
        // that the menu bar should already show recording before the
        // metadata arrives. We can't easily delay the synchronous stub,
        // but we can observe that after the trigger fires, isRecording
        // is true even though recordingMeetingName starts nil (placeholder).
        f.prompter.nextResponse = inputs("Demo")
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        // Yield so the start Shortcut + setRecording(true) lands.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(f.menuBar.isRecording == true)
        // Long enough for the detached metadata task to resolve too.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.menuBar.recordingMeetingName == "Demo")
    }

    @Test
    func firingHotkey_passesOrgsAndDefaultToPrompter() async throws {
        let f = makeFixture()
        let acme = try f.organizations.upsert(Organization(name: "Acme", isDefault: true))
        f.prompter.nextResponse = inputs("Sync")
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.prompter.lastOrganizations.map(\.id) == [acme.id])
        #expect(f.prompter.lastDefaultOrgId == acme.id)
    }

    @Test
    func firingHotkey_storesContextSnapshotWithCompiledPrompt() async throws {
        let f = makeFixture()
        let acme = try f.organizations.upsert(Organization(
            name: "Acme",
            staffNames: ["Alice"]
        ))
        f.prompter.nextResponse = MeetingStartInputs(
            meetingName: "Standup",
            organizationId: acme.id,
            meetingSpecificContext: "Quarterly check-in"
        )
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = f.meetingContextStore.pending?.snapshot
        #expect(snapshot?.meetingName == "Standup")
        #expect(snapshot?.organizationId == acme.id)
        #expect(snapshot?.meetingSpecificContext == "Quarterly check-in")
        #expect(snapshot?.resolvedCompiledContext.contains("Organization: Acme") == true)
        #expect(snapshot?.resolvedCompiledContext.contains("Staff: Alice") == true)
        #expect(snapshot?.resolvedCompiledContext.contains("Quarterly check-in") == true)
    }

    @Test
    func firingHotkey_builtIn_appendsTwoInfoEntries_immediateStartAndPostMetadata() async throws {
        let f = makeFixture()
        let acme = try f.organizations.upsert(Organization(name: "Acme"))
        f.prompter.nextResponse = MeetingStartInputs(
            meetingName: "Demo Meeting",
            organizationId: acme.id
        )
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Two info entries: immediate "started — awaiting" then "details saved".
        // entries is newest-first, so [0] = "details saved", [1] = "started".
        #expect(f.auditLog.entries.count >= 2)
        #expect(f.auditLog.entries[0].kind == .info)
        #expect(f.auditLog.entries[0].message.contains("Demo Meeting") == true)
        #expect(f.auditLog.entries[0].message.contains("Acme") == true)
        #expect(f.auditLog.entries[0].message.contains("details") == true)
        #expect(f.auditLog.entries.last?.message.contains("awaiting") == true)
    }

    @Test
    func firingHotkey_builtIn_userSkipsMetadata_logsInfoAndKeepsRecording() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = nil
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        // v0.4.1: recording has already started, so cancel is an info
        // event (not a failure) and the menu bar still shows recording.
        #expect(f.auditLog.entries.contains { $0.message.contains("awaiting") })
        #expect(f.auditLog.entries.contains { $0.message.contains("skipped") })
        #expect(f.auditLog.entries.allSatisfy { $0.kind == .info })
        #expect(f.menuBar.isRecording == true)
        #expect(f.menuBar.recordingMeetingName == nil)
        // No snapshot stamped — pipeline will process the audio with
        // basename + no context (same as non-Jot-kicked recordings).
        #expect(f.meetingContextStore.pending == nil)
    }

    @Test
    func firingHotkey_builtIn_whileRecording_stopsAndUpdatesMenuBar() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = inputs("Standup")
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.menuBar.isRecording == true)
        #expect(f.menuBar.recordingMeetingName == "Standup")

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.menuBar.isRecording == false)
        #expect(f.menuBar.recordingMeetingName == nil)
        #expect(f.prompter.askCount == 1)
        #expect(f.opener.openedURLs.count == 2)
        #expect(f.opener.openedURLs[0].queryValue(named: "name") == f.settings.startShortcutName)
        #expect(f.opener.openedURLs[1].queryValue(named: "name") == f.settings.stopShortcutName)
        #expect(f.opener.openedURLs[1].queryValue(named: "input") == nil)
        #expect(f.auditLog.entries.first?.message.contains("stopped") == true)
    }

    @Test
    func firingHotkey_builtIn_audioHijackMissing_logsFailure() async throws {
        let f = makeFixture(audioHijackInstalled: false)
        f.prompter.nextResponse = inputs("X")
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.auditLog.entries.first?.kind == .failure)
        #expect(f.auditLog.entries.first?.message.contains("not installed") == true)
        #expect(f.coordinator.lastTriggerError?.contains("not installed") == true)
    }

    @Test
    func firingHotkey_builtIn_urlOpenFailure_surfacesActionableError() async throws {
        let opener = RecordingURLOpener()
        opener.nextError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Shortcuts unavailable"
        ])
        let f = makeFixture(opener: opener)
        f.prompter.nextResponse = inputs("X")
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.auditLog.entries.first?.kind == .failure)
        #expect(f.coordinator.lastTriggerError?.contains(f.settings.startShortcutName) == true)
        #expect(f.coordinator.lastTriggerError?.contains("Shortcuts app") == true)
    }

    @Test
    func firingHotkey_success_clearsLastTriggerError() async throws {
        let f = makeFixture(audioHijackInstalled: false)
        f.prompter.nextResponse = inputs("X")
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()
        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.coordinator.lastTriggerError != nil)

        let g = makeFixture()
        g.prompter.nextResponse = inputs("Y")
        g.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await g.coordinator.bootstrap()
        g.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(g.coordinator.lastTriggerError == nil)
    }

    // MARK: - Trigger → custom Shortcut (override)

    @Test
    func firingHotkey_customShortcut_opensRunShortcutURL() async throws {
        let f = makeFixture()
        f.settings.useBuiltInRecording = false
        f.settings.customShortcutName = "Custom"
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.opener.openedURLs.count == 1)
        #expect(f.opener.openedURLs[0].queryValue(named: "name") == "Custom")
        #expect(f.prompter.askCount == 0)
        #expect(f.opener.openedURLs[0].queryValue(named: "input") == nil)
    }

    @Test
    func firingHotkey_customShortcut_failure_logsFailure() async throws {
        let opener = RecordingURLOpener()
        opener.nextError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Shortcuts unavailable"
        ])
        let f = makeFixture(opener: opener)
        f.settings.useBuiltInRecording = false
        f.settings.customShortcutName = "Missing"
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.auditLog.entries.first?.kind == .failure)
    }

    // MARK: - Test-recording button

    @Test
    func testRecordingNow_builtIn_returnsNilOnSuccess() async {
        let f = makeFixture()
        f.prompter.nextResponse = inputs("T")
        let error = await f.coordinator.testRecordingNow()
        #expect(error == nil)
        #expect(f.opener.openedURLs.count == 1)
        #expect(f.opener.openedURLs[0].queryValue(named: "name") == f.settings.startShortcutName)
    }

    @Test
    func testRecordingNow_builtIn_userSkipsMetadata_returnsNilAndLogsInfoOnly() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = nil
        let error = await f.coordinator.testRecordingNow()
        #expect(error == nil)
        // v0.4.1: skipping the prompt isn't an error — recording is
        // already running. Audit gets info rows (started + skipped),
        // no failure row.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.auditLog.entries.allSatisfy { $0.kind == .info })
    }

    @Test
    func testRecordingNow_customShortcut_returnsNilOnSuccess() async {
        let f = makeFixture()
        f.settings.useBuiltInRecording = false
        f.settings.customShortcutName = "Manual"
        let error = await f.coordinator.testRecordingNow()
        #expect(error == nil)
        #expect(f.opener.openedURLs.first?.queryValue(named: "name") == "Manual")
    }

    @Test
    func testRecordingNow_customShortcut_returnsErrorOnFailure() async {
        let opener = RecordingURLOpener()
        opener.nextError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "oops"
        ])
        let f = makeFixture(opener: opener)
        f.settings.useBuiltInRecording = false
        f.settings.customShortcutName = "X"
        let error = await f.coordinator.testRecordingNow()
        #expect(error != nil)
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
