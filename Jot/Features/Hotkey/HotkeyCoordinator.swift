import Foundation
import Observation

/// SwiftUI-side owner of the global hotkey + Apple Shortcut wiring.
///
/// Responsibilities:
///   1. Whenever `AppSettings.recordingHotkey` changes, (re)register the
///      hotkey with the `HotkeyRegistrar`.
///   2. When the hotkey fires, kick off the user-configured Apple Shortcut
///      via `ShortcutInvoker`, and log an audit entry either way.
///   3. Surface any registration failure as `registrationError` so
///      `HotkeySection` can show it inline (typical cause: another app
///      already grabbed the same combo; or the user hasn't granted
///      Accessibility permission yet).
///
/// Owned by `JotApp` via `@State` so it lives for the app's whole lifetime.
@MainActor
@Observable
final class HotkeyCoordinator {

    private let settings: AppSettings
    private let registrar: any HotkeyRegistering
    private let invoker: ShortcutInvoker
    private let audioHijack: AudioHijackController
    private let menuBar: MenuBarController
    private let auditLog: AuditLogStore
    private let organizations: OrganizationStore
    private let meetingContextStore: MeetingContextStore

    /// One-line user-facing error if the most recent registration attempt
    /// failed (`HotkeyError.registrationFailed`). `nil` on success.
    private(set) var registrationError: String?

    /// One-line user-facing error if the most recent hotkey-triggered
    /// recording attempt failed (e.g., Automation permission denied,
    /// Audio Hijack not installed, custom shortcut returned non-zero).
    /// `nil` while a recording is in progress / on success / on cancel.
    /// Cleared on the next successful trigger.
    private(set) var lastTriggerError: String?

    /// The combo we most recently registered. Used by `bootstrap()` to skip
    /// no-op re-registrations and by the UI to confirm "this combo is live".
    private(set) var activeHotkey: KeyCombo?

    private var observationTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        registrar: any HotkeyRegistering,
        invoker: ShortcutInvoker,
        audioHijack: AudioHijackController,
        menuBar: MenuBarController,
        auditLog: AuditLogStore,
        organizations: OrganizationStore,
        meetingContextStore: MeetingContextStore
    ) {
        self.settings = settings
        self.registrar = registrar
        self.invoker = invoker
        self.audioHijack = audioHijack
        self.menuBar = menuBar
        self.auditLog = auditLog
        self.organizations = organizations
        self.meetingContextStore = meetingContextStore
    }

    /// Force-stop the active recording (the "Stop recording" menu-bar
    /// dropdown action). No-op if not currently recording.
    func stopRecordingNow() async {
        do {
            try await audioHijack.stopRecordingIfActive(
                stopShortcutName: settings.stopShortcutName
            )
            menuBar.setRecording(false)
            meetingContextStore.recordStopped()
            auditLog.append(.init(
                kind: .info,
                sourcePath: "AudioHijack",
                message: "Stopped recording (manual)"
            ))
        } catch let error as AudioHijackRecordingError {
            auditLog.append(.init(
                kind: .failure,
                sourcePath: "AudioHijack",
                message: error.userFacingMessage
            ))
        } catch {
            auditLog.append(.init(
                kind: .failure,
                sourcePath: "AudioHijack",
                message: error.localizedDescription
            ))
        }
    }

    // MARK: - Lifecycle

    /// Apply the current settings hotkey and start observing for changes.
    /// Call once at app launch.
    func bootstrap() async {
        applyCurrentHotkey()
        observationTask = Task { [weak self] in
            await self?.observeSettings()
        }
    }

    /// User clicked "Test recording" in Settings. Runs the currently-active
    /// recording toggle path (built-in AH or custom Shortcut) now and
    /// returns a user-facing error string on failure.
    @discardableResult
    func testRecordingNow() async -> String? {
        if settings.useBuiltInRecording {
            do {
                try await runBuiltInToggle(source: "Manual")
                return nil
            } catch let error as AudioHijackRecordingError {
                auditLog.append(.init(
                    kind: .failure,
                    sourcePath: "AudioHijack",
                    message: error.userFacingMessage
                ))
                return error.userFacingMessage
            } catch {
                auditLog.append(.init(
                    kind: .failure,
                    sourcePath: "AudioHijack",
                    message: error.localizedDescription
                ))
                return error.localizedDescription
            }
        } else {
            // Custom Apple Shortcut path.
            do {
                try await invoker.run(shortcutName: settings.customShortcutName)
                auditLog.append(.init(
                    kind: .info,
                    sourcePath: settings.customShortcutName,
                    message: "Manual: triggered '\(settings.customShortcutName)' shortcut"
                ))
                return nil
            } catch let error as ShortcutError {
                auditLog.append(.init(
                    kind: .failure,
                    sourcePath: settings.customShortcutName,
                    message: error.userFacingMessage
                ))
                return error.userFacingMessage
            } catch {
                auditLog.append(.init(
                    kind: .failure,
                    sourcePath: settings.customShortcutName,
                    message: error.localizedDescription
                ))
                return error.localizedDescription
            }
        }
    }

    // MARK: - Settings observation

    private func observeSettings() async {
        while !Task.isCancelled {
            await waitForChange()
            applyCurrentHotkey()
        }
    }

    private func waitForChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = settings.recordingHotkey
            } onChange: {
                continuation.resume()
            }
        }
    }

    // MARK: - Registration

    private func applyCurrentHotkey() {
        guard let combo = settings.recordingHotkey else {
            registrar.unregister()
            activeHotkey = nil
            registrationError = nil
            return
        }

        // Skip if nothing changed.
        if combo == activeHotkey, registrationError == nil { return }

        do {
            try registrar.register(combo) { [weak self] in
                self?.handleTrigger()
            }
            activeHotkey = combo
            registrationError = nil
        } catch let error as HotkeyError {
            activeHotkey = nil
            registrationError = describe(error)
            Log.app.warning("Hotkey registration failed: \(self.describe(error), privacy: .public)")
        } catch {
            activeHotkey = nil
            registrationError = error.localizedDescription
        }
    }

    private func describe(_ error: HotkeyError) -> String {
        switch error {
        case .registrationFailed(let status):
            // -9878 is `eventHotKeyExistsErr` — Carbon's signal that another
            // app already owns the combo. Worth calling out specifically.
            if status == -9878 {
                return "That hotkey is already in use by another app. Pick a different combination."
            }
            return "Couldn't register hotkey (status \(status)). If this is the first time, grant Jot access in System Settings → Privacy & Security → Accessibility and try again."
        }
    }

    // MARK: - Trigger

    private func handleTrigger() {
        Log.app.info("Recording hotkey fired")
        Task { @MainActor [weak self] in
            await self?.fireShortcut()
        }
    }

    private func fireShortcut() async {
        if settings.useBuiltInRecording {
            await fireBuiltInAudioHijack()
        } else {
            await fireCustomShortcut()
        }
    }

    private func fireBuiltInAudioHijack() async {
        do {
            try await runBuiltInToggle(source: "Hotkey")
            lastTriggerError = nil
        } catch let error as AudioHijackRecordingError {
            lastTriggerError = error.userFacingMessage
            auditLog.append(.init(
                kind: .failure,
                sourcePath: "AudioHijack",
                message: error.userFacingMessage
            ))
        } catch {
            lastTriggerError = error.localizedDescription
            auditLog.append(.init(
                kind: .failure,
                sourcePath: "AudioHijack",
                message: error.localizedDescription
            ))
        }
    }

    /// Recording-first toggle: if not currently recording, runs the start
    /// Shortcut immediately and then collects metadata in the background
    /// so the user can fill the prompt while AH is already capturing
    /// audio (v0.4.1, Backlog "start recording on hotkey press"). If
    /// already recording, runs the stop Shortcut and clears the snapshot.
    ///
    /// Throws `AudioHijackRecordingError` on a *real* failure (AH not
    /// installed, Shortcut URL didn't open). User cancellation of the
    /// metadata prompt is **not** an error here — the recording is still
    /// running by that point and "skipped metadata" is just an info row.
    private func runBuiltInToggle(source: String) async throws {
        if menuBar.isRecording {
            try await audioHijack.stopRecording(stopShortcutName: settings.stopShortcutName)
            menuBar.setRecording(false)
            meetingContextStore.recordStopped()
            auditLog.append(.init(
                kind: .info,
                sourcePath: "AudioHijack",
                message: "\(source): stopped recording"
            ))
            return
        }

        // Start path: fire AH first so recording is already running before
        // the user sees the prompt.
        let startedAt = try await audioHijack.startRecording(
            startShortcutName: settings.startShortcutName
        )
        menuBar.setRecording(true, meetingName: nil)
        auditLog.append(.init(
            kind: .info,
            sourcePath: "AudioHijack",
            message: "\(source): started recording — awaiting meeting details"
        ))

        // Collect metadata concurrently. The prompt may be modal (NSAlert),
        // but AH is recording in its own process so the user's actual
        // meeting capture is unaffected. The detached task is fine to
        // outlive this call — its only effect is to update the in-flight
        // snapshot + menu bar label when the user submits.
        Task { @MainActor [weak self] in
            await self?.collectMetadataAndStamp(startedAt: startedAt, source: source)
        }
    }

    /// Prompt for meeting metadata and, on submit, stamp the snapshot
    /// store with `at: startedAt` so the pipeline's time-window guard
    /// matches the file AH produced. On cancel, leave the recording
    /// running and log an info row; the file will process with audio
    /// basename + no context, same as a non-Jot-kicked recording.
    private func collectMetadataAndStamp(startedAt: Date, source: String) async {
        let inputs = await audioHijack.collectMetadata(
            organizations: organizations.organizations,
            defaultOrgId: organizations.defaultOrg()?.id
        )
        guard let inputs else {
            auditLog.append(.init(
                kind: .info,
                sourcePath: "AudioHijack",
                message: "\(source): meeting details skipped — recording continues"
            ))
            return
        }

        let org = inputs.organizationId.flatMap { organizations.organization(id: $0) }
        let compiled = ContextCompiler.compile(
            meetingName: inputs.meetingName,
            meetingSpecificContext: inputs.meetingSpecificContext,
            organization: org
        )
        meetingContextStore.recordStarted(
            meetingName: inputs.meetingName,
            organizationId: inputs.organizationId,
            organizationName: org?.name,
            meetingSpecificContext: inputs.meetingSpecificContext,
            resolvedCompiledContext: compiled,
            at: startedAt
        )
        menuBar.setRecording(true, meetingName: inputs.meetingName)
        let orgSuffix = org.map { " · \($0.name)" } ?? " · No Organization"
        auditLog.append(.init(
            kind: .info,
            sourcePath: "AudioHijack",
            message: inputs.meetingName.isEmpty
                ? "\(source): meeting details saved"
                : "\(source): meeting details saved — '\(inputs.meetingName)'\(orgSuffix)"
        ))
    }

    private func fireCustomShortcut() async {
        let name = settings.customShortcutName
        do {
            try await invoker.run(shortcutName: name)
            lastTriggerError = nil
            auditLog.append(.init(
                kind: .info,
                sourcePath: name,
                message: "Hotkey triggered '\(name)' shortcut"
            ))
        } catch let error as ShortcutError {
            lastTriggerError = error.userFacingMessage
            auditLog.append(.init(
                kind: .failure,
                sourcePath: name,
                message: error.userFacingMessage
            ))
        } catch {
            lastTriggerError = error.localizedDescription
            auditLog.append(.init(
                kind: .failure,
                sourcePath: name,
                message: error.localizedDescription
            ))
        }
    }
}
