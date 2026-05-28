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
        prompter: StubMeetingNamePrompter? = nil,
        audioHijackInstalled: Bool = true
    ) -> (
        coordinator: HotkeyCoordinator,
        settings: AppSettings,
        registrar: FakeHotkeyRegistrar,
        opener: RecordingURLOpener,
        prompter: StubMeetingNamePrompter,
        menuBar: MenuBarController,
        auditLog: AuditLogStore
    ) {
        let registrar = registrar ?? FakeHotkeyRegistrar()
        let opener = opener ?? RecordingURLOpener()
        let prompter = prompter ?? StubMeetingNamePrompter()
        let defaults = EphemeralUserDefaults.make()
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let auditLog = AuditLogStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("jot-hotkey-coord-\(UUID().uuidString).json")
        )
        let presence = AudioHijackPresence(
            bundleIDLookup: { _ in
                audioHijackInstalled ? URL(fileURLWithPath: "/Applications/Audio Hijack.app") : nil
            },
            pathExistsCheck: { _ in false },
            bundleIDFromURL: { _ in
                audioHijackInstalled ? "com.rogueamoeba.audiohijack" : nil
            }
        )
        // One invoker shared between AudioHijackController and HotkeyCoordinator
        // — both ask macOS to open `shortcuts://run-shortcut?…` URLs, just with
        // different names, so the recording opener captures every URL.
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
            auditLog: auditLog
        )
        return (coordinator, settings, registrar, opener, prompter, menuBar, auditLog)
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
        // recordingHotkey defaults to nil
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
        // The "already in use by another app" message is specifically called out.
        #expect(f.coordinator.registrationError?.contains("already in use") == true)
    }

    // MARK: - Trigger → built-in Audio Hijack (default)

    @Test
    func firingHotkey_default_opensStartShortcutURL() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = "Standup"
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Built-in path: prompt + shortcuts://run-shortcut?name=Start&input=…
        #expect(f.prompter.askCount == 1)
        #expect(f.opener.openedURLs.count == 1)
        let url = f.opener.openedURLs[0]
        #expect(url.scheme == "shortcuts")
        #expect(url.host == "run-shortcut")
        #expect(url.queryValue(named: "name") == f.settings.startShortcutName)
        #expect(url.queryValue(named: "input") == "Standup")
    }

    @Test
    func firingHotkey_builtIn_appendsInfoAuditEntryWithMeetingName() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = "Demo Meeting"
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.auditLog.entries.first?.kind == .info)
        #expect(f.auditLog.entries.first?.message.contains("Demo Meeting") == true)
    }

    @Test
    func firingHotkey_builtIn_userCancels_addsNoAuditEntry() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = nil    // user cancelled the dialog
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.auditLog.entries.isEmpty, "Cancel should be silent — no audit row")
    }

    @Test
    func firingHotkey_builtIn_whileRecording_stopsAndUpdatesMenuBar() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = "Standup"
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        // First press: start
        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.menuBar.isRecording == true)
        #expect(f.menuBar.recordingMeetingName == "Standup")

        // Second press: should stop (no prompt)
        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.menuBar.isRecording == false)
        #expect(f.menuBar.recordingMeetingName == nil)
        // Prompter was asked only once (for the start, not the stop).
        #expect(f.prompter.askCount == 1)
        // Two URLs opened: start, then stop.
        #expect(f.opener.openedURLs.count == 2)
        #expect(f.opener.openedURLs[0].queryValue(named: "name") == f.settings.startShortcutName)
        #expect(f.opener.openedURLs[1].queryValue(named: "name") == f.settings.stopShortcutName)
        // Stop never sends an input.
        #expect(f.opener.openedURLs[1].queryValue(named: "input") == nil)
        // Final audit entry is the "stopped" info row.
        #expect(f.auditLog.entries.first?.message.contains("stopped") == true)
    }

    @Test
    func firingHotkey_builtIn_audioHijackMissing_logsFailure() async throws {
        let f = makeFixture(audioHijackInstalled: false)
        f.prompter.nextResponse = "X"
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.auditLog.entries.first?.kind == .failure)
        #expect(f.auditLog.entries.first?.message.contains("not installed") == true)
        // Inline display: same message surfaces on `lastTriggerError`.
        #expect(f.coordinator.lastTriggerError?.contains("not installed") == true)
    }

    @Test
    func firingHotkey_builtIn_urlOpenFailure_surfacesActionableError() async throws {
        let opener = RecordingURLOpener()
        opener.nextError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Shortcuts unavailable"
        ])
        let f = makeFixture(opener: opener)
        f.prompter.nextResponse = "X"
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
        // First press fails (no AH) → lastTriggerError populated.
        let f = makeFixture(audioHijackInstalled: false)
        f.prompter.nextResponse = "X"
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()
        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.coordinator.lastTriggerError != nil)

        // Fresh happy fixture: fire and verify lastTriggerError stays nil.
        let g = makeFixture()
        g.prompter.nextResponse = "Y"
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
        // Custom mode never prompts and never sends input.
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
        f.prompter.nextResponse = "T"
        let error = await f.coordinator.testRecordingNow()
        #expect(error == nil)
        // Built-in test: one Start Shortcut URL opened.
        #expect(f.opener.openedURLs.count == 1)
        #expect(f.opener.openedURLs[0].queryValue(named: "name") == f.settings.startShortcutName)
    }

    @Test
    func testRecordingNow_builtIn_userCancelReturnsNilWithoutLogging() async {
        let f = makeFixture()
        f.prompter.nextResponse = nil
        let error = await f.coordinator.testRecordingNow()
        #expect(error == nil)
        #expect(f.auditLog.entries.isEmpty)
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
