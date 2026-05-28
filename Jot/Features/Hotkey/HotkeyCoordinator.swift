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
                let action = try await audioHijack.toggleRecording(
                    isCurrentlyRecording: menuBar.isRecording,
                    startShortcutName: settings.startShortcutName,
                    stopShortcutName: settings.stopShortcutName,
                    organizations: organizations.organizations,
                    defaultOrgId: organizations.defaultOrg()?.id
                )
                applyAudioHijackAction(action, source: "Manual")
                return nil
            } catch let error as AudioHijackRecordingError {
                if error == .userCancelled { return nil } // Not really a failure.
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
            let action = try await audioHijack.toggleRecording(
                isCurrentlyRecording: menuBar.isRecording,
                startShortcutName: settings.startShortcutName,
                stopShortcutName: settings.stopShortcutName,
                organizations: organizations.organizations,
                defaultOrgId: organizations.defaultOrg()?.id
            )
            applyAudioHijackAction(action, source: "Hotkey")
            lastTriggerError = nil
        } catch let error as AudioHijackRecordingError {
            if error == .userCancelled { return } // Quiet cancel — no audit row.
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

    /// Shared post-action handling: drive the menu-bar recording indicator
    /// and append the right audit entry. Used by both the hotkey trigger
    /// and the Test recording button.
    private func applyAudioHijackAction(_ action: RecordingAction, source: String) {
        switch action {
        case .started(let inputs):
            menuBar.setRecording(true, meetingName: inputs.meetingName)
            let org = inputs.organizationId.flatMap { organizations.organization(id: $0) }
            let compiled = ContextCompiler.compile(
                meetingName: inputs.meetingName,
                meetingSpecificContext: inputs.meetingSpecificContext,
                organization: org
            )
            meetingContextStore.recordStarted(
                meetingName: inputs.meetingName,
                organizationId: inputs.organizationId,
                meetingSpecificContext: inputs.meetingSpecificContext,
                resolvedCompiledContext: compiled
            )
            let orgSuffix = org.map { " · \($0.name)" } ?? " · No Organization"
            auditLog.append(.init(
                kind: .info,
                sourcePath: "AudioHijack",
                message: inputs.meetingName.isEmpty
                    ? "\(source): started recording"
                    : "\(source): started recording '\(inputs.meetingName)'\(orgSuffix)"
            ))
        case .stopped:
            menuBar.setRecording(false)
            meetingContextStore.recordStopped()
            auditLog.append(.init(
                kind: .info,
                sourcePath: "AudioHijack",
                message: "\(source): stopped recording"
            ))
        }
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
