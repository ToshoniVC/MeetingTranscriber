import Foundation
import Observation

/// `@Observable` wrapper around any `LoginItemControlling` so SwiftUI can
/// bind to status + error without knowing about `SMAppService`.
///
/// Owned by `JotApp` via `@State`. SystemSection reads `statusMessage` /
/// `lastError` for its caption, and calls `apply(enabled:)` from the toggle.
@MainActor
@Observable
final class LoginItemController {

    private let manager: any LoginItemControlling

    /// The most recent error from `setEnabled(_:)`, if any. `nil` when the
    /// last toggle succeeded.
    private(set) var lastError: String?

    /// Cached status. Refreshed after every `apply(enabled:)` call.
    private(set) var status: LoginItemStatus

    init(manager: any LoginItemControlling) {
        self.manager = manager
        self.status = manager.status
    }

    /// User-visible status caption shown in `SystemSection`. Prefers the
    /// last error message when set, falls back to a status-derived line.
    var statusMessage: String {
        if let lastError { return lastError }
        switch status {
        case .enabled:
            return "Jot will launch at login."
        case .notRegistered:
            return "Disabled — toggle on to enable."
        case .notFound:
            return "Login item not found — toggle on to register."
        case .requiresApproval:
            return "Awaiting approval. Flip Jot on in System Settings → Login Items."
        }
    }

    /// Try to flip the registration. Captures any error into `lastError`
    /// and refreshes `status` from the underlying manager so the UI shows
    /// the actual state (which may differ from what the user requested,
    /// e.g., when approval is pending).
    func apply(enabled: Bool) {
        do {
            try manager.setEnabled(enabled)
            lastError = nil
        } catch let error as LoginItemError {
            lastError = error.userFacingMessage
        } catch {
            lastError = error.localizedDescription
        }
        status = manager.status
    }
}
