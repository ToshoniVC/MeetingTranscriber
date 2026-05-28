import AppKit
import Foundation

/// Errors `AudioHijackController` can surface.
enum AudioHijackRecordingError: Error, Equatable {
    /// User dismissed the meeting-name prompt — not an error per se, but
    /// we still need to abort the flow.
    case userCancelled

    /// Audio Hijack isn't installed (the `AudioHijackPresence` checker said
    /// so before the call). Surfaces an actionable message to the user.
    case audioHijackNotInstalled

    /// Couldn't hand the `shortcuts://run-shortcut?name=…` URL off to
    /// macOS — usually because the name was empty or, vanishingly rare,
    /// Shortcuts isn't installed. The `detail` is the underlying message
    /// from `NSWorkspace.open`.
    ///
    /// Note: this case does **not** fire when the named Shortcut doesn't
    /// exist in the user's library. URL-scheme invocation only tells us
    /// whether the URL was accepted; the Shortcut's runtime success is
    /// invisible to us. Mis-named Shortcuts surface their own error
    /// inside the Shortcuts app, not back to Jot.
    case shortcutOpenFailed(name: String, detail: String)

    var userFacingMessage: String {
        switch self {
        case .userCancelled:
            return "Recording cancelled."
        case .audioHijackNotInstalled:
            return "Audio Hijack is not installed. Install it from rogueamoeba.com/audiohijack/."
        case .shortcutOpenFailed(let name, let detail):
            let suffix = detail.isEmpty ? "" : " (\(detail.prefix(160)))"
            return "Couldn't open Shortcut '\(name)' via Shortcuts. Make sure the Shortcuts app is installed and the Shortcut exists.\(suffix)"
        }
    }
}

/// Outcome of `toggleRecording()` — drives UI feedback and the menu-bar
/// recording indicator. The `.started` case carries the full
/// `MeetingStartInputs` so the caller (HotkeyCoordinator) can stamp the
/// in-flight `MeetingContextStore` snapshot.
enum RecordingAction: Equatable, Sendable {
    case started(inputs: MeetingStartInputs)
    case stopped
}

/// The built-in "out-of-the-box" recording toggle. Per PRD §5 the user owns
/// the recording app (Audio Hijack 4); Jot only kicks off the action.
///
/// Implementation: AH4 has **no AppleScript dictionary** — it exposes a
/// `Run/Stop Session` App Intent (and a few others) that are only reachable
/// via the macOS Shortcuts app. So Jot runs two user-authored Shortcuts by
/// asking macOS to open `shortcuts://run-shortcut?name=…` URLs via
/// `NSWorkspace.open`. The Shortcuts app then runs the workflow in its
/// own (non-sandboxed) process:
///   - `startShortcutName` — runs `Run/Stop Session` with `state = running`
///   - `stopShortcutName`  — runs `Run/Stop Session` with `state = stopped`
///
/// We previously spawned `/usr/bin/shortcuts` via `Process`, but the CLI
/// inherits our App Sandbox and crashes on a `Data.write(to:)` with a nil
/// URL when it tries to touch paths that don't exist inside our container.
/// URL-scheme invocation sidesteps the issue entirely.
///
/// The hotkey acts as a **toggle**: pressing it while Jot's local view says
/// "recording" runs the stop Shortcut (no prompt). Pressing it while idle
/// asks for a meeting name and runs the start Shortcut (the meeting name is
/// piped to stdin so the Shortcut can use it for the recording filename).
///
/// Owned by `JotApp`, called by `HotkeyCoordinator` whenever
/// `AppSettings.useBuiltInRecording == true`. The single-Shortcut custom
/// override path lives in `HotkeyCoordinator.fireCustomShortcut()` and uses
/// `ShortcutInvoker` directly.
@MainActor
@Observable
final class AudioHijackController {

    private let prompter: any MeetingStartPrompting
    private let invoker: ShortcutInvoker
    private let presence: AudioHijackPresence

    init(
        prompter: any MeetingStartPrompting,
        invoker: ShortcutInvoker,
        presence: AudioHijackPresence
    ) {
        self.prompter = prompter
        self.invoker = invoker
        self.presence = presence
    }

    /// Toggle Audio Hijack based on the caller's view of state:
    ///   - `isCurrentlyRecording == true`  → run the stop Shortcut, return
    ///     `.stopped`.
    ///   - `isCurrentlyRecording == false` → ask for a meeting name, run the
    ///     start Shortcut with the name on stdin, return `.started(name)`.
    ///
    /// The caller (`HotkeyCoordinator` via `MenuBarController.isRecording`)
    /// owns the truth. We can't probe AH4 — it has no AppleScript and no
    /// public "is recording?" intent — so we trust the caller's bookkeeping.
    /// The trade-off: if the user toggles AH outside Jot, our state can
    /// briefly mismatch. Pressing the hotkey one extra time self-corrects.
    func toggleRecording(
        isCurrentlyRecording: Bool,
        startShortcutName: String,
        stopShortcutName: String,
        organizations: [Organization],
        defaultOrgId: UUID?
    ) async throws -> RecordingAction {
        guard presence.isInstalled else {
            throw AudioHijackRecordingError.audioHijackNotInstalled
        }

        if isCurrentlyRecording {
            try await runShortcut(name: stopShortcutName, input: nil)
            Log.app.info("AudioHijack: stop Shortcut ran")
            return .stopped
        }

        // Not recording (per caller) → prompt for name + org + context + start.
        guard let inputs = await prompter.ask(
            organizations: organizations,
            defaultOrgId: defaultOrgId
        ) else {
            throw AudioHijackRecordingError.userCancelled
        }
        // Pass the name on stdin only if it's non-empty — saves a useless
        // `--input-path -` argument when the user skipped the field.
        let stdin = inputs.meetingName.isEmpty ? nil : inputs.meetingName
        try await runShortcut(name: startShortcutName, input: stdin)
        Log.app.info("AudioHijack: start Shortcut ran for '\(inputs.meetingName, privacy: .public)'")
        return .started(inputs: inputs)
    }

    /// Force-stop the current recording (used by the menu-bar "Stop recording"
    /// action). Idempotent at the AH side — if AH wasn't recording, the
    /// Shortcut's `Run/Stop Session → state=stopped` is a no-op.
    func stopRecordingIfActive(stopShortcutName: String) async throws {
        guard presence.isInstalled else { return }
        try await runShortcut(name: stopShortcutName, input: nil)
        Log.app.info("AudioHijack: stop Shortcut ran (manual stop)")
    }

    /// Translate `ShortcutError` into our `AudioHijackRecordingError` so
    /// the caller sees one consistent error type.
    private func runShortcut(name: String, input: String?) async throws {
        do {
            try await invoker.run(shortcutName: name, input: input)
        } catch let error as ShortcutError {
            switch error {
            case .openFailed(let detail):
                throw AudioHijackRecordingError.shortcutOpenFailed(name: name, detail: detail)
            }
        }
    }
}
