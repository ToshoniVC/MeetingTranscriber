import Foundation
import ServiceManagement

/// What a login-item status query / mutation returns. Mirrors the relevant
/// subset of `SMAppService.Status` so callers don't have to import
/// `ServiceManagement` just to read the result.
enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    /// User flipped Jot off in System Settings → Login Items. The toggle
    /// in Jot's Settings should reflect this — flipping it back on calls
    /// `register()` again.
    case notFound
    /// User explicitly denied Jot in System Settings. Setting `enabled`
    /// again won't help — we surface a message asking the user to flip
    /// the System Settings switch themselves.
    case requiresApproval

    /// Whether Jot is currently registered to launch at login.
    var isEnabled: Bool { self == .enabled }
}

/// Errors `LoginItemManager` surfaces — typically when SMAppService can't
/// register us (sandbox issue, permission denied, etc.).
enum LoginItemError: Error, Equatable {
    case underlying(String)

    var userFacingMessage: String {
        switch self {
        case .underlying(let message):
            return "Login item registration failed: \(message). Try enabling Jot in System Settings → Login Items."
        }
    }
}

/// Test-substitutable protocol so unit tests don't touch the real
/// `SMAppService.mainApp` (which would persist Jot in the user's actual
/// Login Items list across the test run).
@MainActor
protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Production wrapper around `SMAppService.mainApp`. The "main app" service
/// asks macOS to launch this bundle at login — no separate helper app
/// needed, no extra plist to ship.
@MainActor
final class LoginItemManager: LoginItemControlling {

    var status: LoginItemStatus {
        Self.translate(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("Login item set to \(enabled ? "enabled" : "disabled", privacy: .public)")
        } catch {
            Log.app.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
            throw LoginItemError.underlying(error.localizedDescription)
        }
    }

    /// Map `SMAppService.Status` onto our smaller surface.
    private static func translate(_ raw: SMAppService.Status) -> LoginItemStatus {
        switch raw {
        case .enabled:          return .enabled
        case .notRegistered:    return .notRegistered
        case .notFound:         return .notFound
        case .requiresApproval: return .requiresApproval
        @unknown default:       return .notRegistered
        }
    }
}
