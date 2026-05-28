import Foundation
import Observation

/// `@Observable` holder for the currently-displayed error in the modal
/// inspector. Bound by `MainWindow` to a `.sheet(item:)`. Setting
/// `currentError` to a non-nil value presents the sheet; setting it to nil
/// dismisses.
///
/// Triggered from two places:
///   1. The menu-bar dropdown's "Show error details…" action while the
///      `MenuBarController.iconState` is `.error`.
///   2. An "Open details" tap on an Audit Log row of kind `.failure`.
///
/// The plan (Phase 8 §2) calls this an "error inspector": full message +
/// Copy details + Open Audit Log. We add a small extra niceness — the user
/// can also Copy from the message text directly because `.textSelection`
/// is enabled on the inspector's body.
///
/// Owned by `JotApp` and injected through the environment.
@MainActor
@Observable
final class ErrorInspector {

    /// Currently-displayed error details. SwiftUI's `.sheet(item:)` shows
    /// the inspector iff this is non-nil. Identifiable so SwiftUI can tell
    /// distinct errors apart when fired in quick succession.
    var currentError: ErrorDetails?

    struct ErrorDetails: Identifiable, Equatable {
        /// Fresh UUID per show() — distinguishes presentations even when
        /// the error message is identical (e.g., same failure retried).
        let id: UUID
        /// Short label shown in the inspector header.
        let title: String
        /// One-paragraph user-facing description; `.textSelection(.enabled)`
        /// on the view means the user can highlight and copy any part.
        let message: String
        /// Path of the file the error relates to. Optional because some
        /// errors aren't file-scoped (e.g., "Pipeline failed to start").
        let sourcePath: String?
        /// When the underlying event happened.
        let timestamp: Date

        init(
            id: UUID = UUID(),
            title: String,
            message: String,
            sourcePath: String?,
            timestamp: Date
        ) {
            self.id = id
            self.title = title
            self.message = message
            self.sourcePath = sourcePath
            self.timestamp = timestamp
        }
    }

    init() {}

    /// Present the inspector from an Audit Log row tap.
    func show(from entry: AuditLogEntry) {
        currentError = ErrorDetails(
            title: "Pipeline error",
            message: entry.message,
            sourcePath: entry.sourcePath,
            timestamp: entry.timestamp
        )
    }

    /// Present the inspector from the menu-bar dropdown while the icon is
    /// in `.error` state. No-op for any other state — that lets the caller
    /// pass `menuBar.iconState` unconditionally without branching.
    func show(pipelineState: PipelineState) {
        guard case .error(let url, let message) = pipelineState else { return }
        currentError = ErrorDetails(
            title: "Pipeline error",
            message: message,
            sourcePath: url.path(percentEncoded: false),
            timestamp: Date()
        )
    }

    func dismiss() {
        currentError = nil
    }
}
