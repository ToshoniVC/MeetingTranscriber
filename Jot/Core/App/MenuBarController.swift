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

    init() {}

    // MARK: - Convenience

    /// `true` when the icon should show the "actively processing" animation.
    var isProcessing: Bool {
        if case .processing = iconState { return true }
        return false
    }

    /// One-line description of the current state, suitable for the menu-bar
    /// dropdown's status row.
    var statusLine: String {
        switch iconState {
        case .notConfigured: return "Not yet configured"
        case .idle:          return "Idle — watching for recordings"
        case .processing(let url): return "Transcribing \(url.lastPathComponent)…"
        case .error(_, let message): return "Error: \(message)"
        }
    }
}
