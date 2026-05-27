import Testing
import Foundation
import AppKit
@testable import Jot

/// Tests for `HotkeyCoordinator` — applies the current hotkey, surfaces
/// errors, fires the shortcut when triggered.
///
/// Uses `FakeHotkeyRegistrar` + `RecordingProcessRunner` so no global
/// Carbon hotkey is registered and no `/usr/bin/shortcuts` is spawned.
@MainActor
struct HotkeyCoordinatorTests {

    private func makeFixture(
        registrar: FakeHotkeyRegistrar? = nil,
        runner: RecordingProcessRunner? = nil,
        prompter: StubMeetingNamePrompter? = nil,
        audioHijackInstalled: Bool = true
    ) -> (
        coordinator: HotkeyCoordinator,
        settings: AppSettings,
        registrar: FakeHotkeyRegistrar,
        runner: RecordingProcessRunner,
        prompter: StubMeetingNamePrompter,
        menuBar: MenuBarController,
        auditLog: AuditLogStore
    ) {
        let registrar = registrar ?? FakeHotkeyRegistrar()
        let runner = runner ?? RecordingProcessRunner()
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
        // — they both spawn `/usr/bin/shortcuts run …`, just with different
        // names, so the recording runner sees both kinds of calls.
        let invoker = ShortcutInvoker(runner: runner)
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
        return (coordinator, settings, registrar, runner, prompter, menuBar, auditLog)
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
    func firingHotkey_default_runsBuiltInStartShortcut() async throws {
        let f = makeFixture()
        f.prompter.nextResponse = "Standup"
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Built-in path: prompt + Start Shortcut via /usr/bin/shortcuts.
        #expect(f.prompter.askCount == 1)
        #expect(f.runner.calls.count == 1)
        #expect(f.runner.calls[0].arguments[0] == "run")
        #expect(f.runner.calls[0].arguments[1] == f.settings.startShortcutName)
        // Meeting name piped via stdin.
        #expect(f.runner.calls[0].stdin == "Standup")
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
        // Two shortcut calls: start, then stop.
        #expect(f.runner.calls.count == 2)
        #expect(f.runner.calls[0].arguments[1] == f.settings.startShortcutName)
        #expect(f.runner.calls[1].arguments[1] == f.settings.stopShortcutName)
        #expect(f.runner.calls[1].stdin == nil)   // stop never pipes stdin
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
    func firingHotkey_builtIn_missingShortcut_surfacesActionableError() async throws {
        let runner = RecordingProcessRunner()
        runner.nextResult = ProcessResult(exitCode: 1, stdout: "", stderr: "Couldn't find shortcut")
        let f = makeFixture(runner: runner)
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
    func firingHotkey_customShortcut_runsShortcutsCLI() async throws {
        let f = makeFixture()
        f.settings.useBuiltInRecording = false
        f.settings.customShortcutName = "Custom"
        f.settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        await f.coordinator.bootstrap()

        f.registrar.fireTrigger()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.runner.calls.first?.arguments == ["run", "Custom"])
        // Custom mode never prompts.
        #expect(f.prompter.askCount == 0)
    }

    @Test
    func firingHotkey_customShortcut_failure_logsFailure() async throws {
        let runner = RecordingProcessRunner()
        runner.nextResult = ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
        let f = makeFixture(runner: runner)
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
        // Built-in test: one Start Shortcut call.
        #expect(f.runner.calls.count == 1)
        #expect(f.runner.calls[0].arguments[1] == f.settings.startShortcutName)
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
        #expect(f.runner.calls.first?.arguments == ["run", "Manual"])
    }

    @Test
    func testRecordingNow_customShortcut_returnsErrorOnFailure() async {
        let runner = RecordingProcessRunner()
        runner.nextResult = ProcessResult(exitCode: 2, stdout: "", stderr: "oops")
        let f = makeFixture(runner: runner)
        f.settings.useBuiltInRecording = false
        f.settings.customShortcutName = "X"
        let error = await f.coordinator.testRecordingNow()
        #expect(error != nil)
    }
}
