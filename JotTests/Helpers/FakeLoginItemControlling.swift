import Foundation
@testable import Jot

/// Test fake for `LoginItemControlling`. Lets tests pin the current status
/// and verify register/unregister calls.
@MainActor
final class FakeLoginItemControlling: LoginItemControlling {

    var status: LoginItemStatus = .notRegistered
    private(set) var setEnabledCalls: [Bool] = []

    /// If non-nil, the next `setEnabled(_:)` throws this.
    var nextSetEnabledError: Error?

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if let nextSetEnabledError {
            self.nextSetEnabledError = nil
            throw nextSetEnabledError
        }
        status = enabled ? .enabled : .notRegistered
    }
}
