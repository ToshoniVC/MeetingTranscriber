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

/// The built-in "out-of-the-box" recording driver. Per PRD §5 the user owns
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
/// **Recording-first UX** (v0.4.1, per Backlog "start recording on hotkey
/// press"): the hotkey runs the start Shortcut *immediately* and only then
/// prompts for meeting metadata. The prompt is collected concurrently while
/// AH is already capturing audio. This is why this controller is split into
/// three single-purpose methods (`startRecording`, `stopRecording`,
/// `collectMetadata`) rather than a single `toggleRecording` — the toggle
/// shape couldn't model "started without metadata, metadata arrives later".
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

    /// Run the start Shortcut now and return the wall-clock timestamp that
    /// recording began. The caller must pass this timestamp back into
    /// `MeetingContextStore.recordStarted(at:)` when metadata arrives later
    /// so the time-window guard in `consume(forFileCreatedAt:)` correctly
    /// matches the produced audio file (which may have been written before
    /// the user finished filling in the metadata prompt).
    ///
    /// We capture `Date()` *immediately before* asking macOS to run the
    /// Shortcut, not after — the audio file's creation date is set by AH
    /// the moment it opens the file for writing, which is essentially
    /// instantaneous after the URL handoff. The window guard has a couple
    /// seconds of slop either side.
    func startRecording(startShortcutName: String) async throws -> Date {
        guard presence.isInstalled else {
            throw AudioHijackRecordingError.audioHijackNotInstalled
        }
        let startedAt = Date()
        try await runShortcut(name: startShortcutName, input: nil)
        Log.app.info("AudioHijack: start Shortcut ran")
        return startedAt
    }

    /// Run the stop Shortcut now. Throws if AH isn't installed (defensive —
    /// the caller usually probes presence first via the menu bar's
    /// recording state, but startRecording could have succeeded against an
    /// AH that was since uninstalled).
    func stopRecording(stopShortcutName: String) async throws {
        guard presence.isInstalled else {
            throw AudioHijackRecordingError.audioHijackNotInstalled
        }
        try await runShortcut(name: stopShortcutName, input: nil)
        Log.app.info("AudioHijack: stop Shortcut ran")
    }

    /// Show the meeting-start prompt and return the user's metadata, or nil
    /// if they cancelled. Does NOT touch Audio Hijack — recording is
    /// expected to already be running. The caller stamps the returned
    /// inputs into `MeetingContextStore` themselves so this method stays
    /// dependency-free.
    func collectMetadata(
        organizations: [Organization],
        defaultOrgId: UUID?
    ) async -> MeetingStartInputs? {
        await prompter.ask(
            organizations: organizations,
            defaultOrgId: defaultOrgId
        )
    }

    /// Force-stop the current recording (used by the menu-bar "Stop recording"
    /// action). Idempotent at the AH side — if AH wasn't recording, the
    /// Shortcut's `Run/Stop Session → state=stopped` is a no-op. Differs
    /// from `stopRecording` in that it silently no-ops when AH isn't
    /// installed (the menu-bar action shouldn't surface an error for a
    /// nice-to-have action).
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
