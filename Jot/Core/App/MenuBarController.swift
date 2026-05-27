import AppKit
import SwiftUI

/// Owns the menu-bar surface and exposes a `PipelineState`-derived
/// `iconState` for the `MenuBarExtra` label in `JotApp.swift`.
///
/// PRD §3.1 calls out three icon states:
///   - Idle: standard monochromatic icon
///   - Processing: subtle animation (we use `.symbolEffect(.pulse)`)
///   - Error: red exclamation
/// We add `notConfigured` for the "user hasn't set Settings up yet" case so
/// the icon can hint at that without lying.
///
/// Phase 8 (UI polish) will replace the `MenuBarExtra` with a custom
/// `NSStatusItem` so a single click on the icon toggles the main window
/// directly (PRD §3.1: "does not use a dropdown menu"). For now the icon
/// shows a dropdown; the icon glyph itself reflects state correctly.
@MainActor
@Observable
final class MenuBarController {

    /// The current pipeline state, mirrored from `PipelineCoordinator`.
    /// `MenuBarExtra` reads this to render the right icon variant.
    var iconState: PipelineState = .notConfigured

    /// Whether Audio Hijack is currently recording (per the most recent
    /// toggle we drove). Surfaces as a red `record.circle.fill` icon in
    /// the menu bar + a "Recording: <name>" row in the dropdown.
    ///
    /// Best-effort: if the user starts/stops AH outside Jot, this stays
    /// in sync the next time the user presses the toggle hotkey (which
    /// re-probes AH's state via AppleScript).
    private(set) var isRecording: Bool = false

    /// The meeting name supplied when the user kicked off the current
    /// recording (`nil` if none was provided or we're not recording).
    private(set) var recordingMeetingName: String?

    init() {}

    // MARK: - Mutators called by HotkeyCoordinator

    /// Record state setter — call after every `AudioHijackController`
    /// transition so the menu bar reflects what AH is actually doing.
    func setRecording(_ recording: Bool, meetingName: String? = nil) {
        isRecording = recording
        recordingMeetingName = recording ? meetingName : nil
    }

    // MARK: - Convenience

    /// `true` when the icon should show the "actively processing" animation.
    var isProcessing: Bool {
        if case .processing = iconState { return true }
        return false
    }

    /// One-line description of the current state, suitable for the menu-bar
    /// dropdown's status row. Recording always takes precedence over
    /// pipeline state — that's the user's most-immediate-concern signal.
    var statusLine: String {
        if isRecording {
            if let name = recordingMeetingName, !name.isEmpty {
                return "Recording: \(name)"
            }
            return "Recording…"
        }
        switch iconState {
        case .notConfigured: return "Not yet configured"
        case .idle:          return "Idle — watching for recordings"
        case .processing(let url): return "Transcribing \(url.lastPathComponent)…"
        case .error(_, let message): return "Error: \(message)"
        }
    }
}
