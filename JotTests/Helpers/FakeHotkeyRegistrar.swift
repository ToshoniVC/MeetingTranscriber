import Foundation
@testable import Jot

/// Test fake for `HotkeyRegistering`. Records what was registered, lets
/// tests fire the trigger on demand, and can be told to throw on `register`
/// to exercise the failure path.
@MainActor
final class FakeHotkeyRegistrar: HotkeyRegistering {

    private(set) var registeredCombo: KeyCombo?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var lastTrigger: (@MainActor () -> Void)?

    /// If non-nil, the next call to `register(_:_:)` throws this and is
    /// treated as a failed registration.
    var nextRegisterError: Error?

    func register(_ combo: KeyCombo, onTrigger: @escaping @MainActor () -> Void) throws {
        registerCallCount += 1
        if let nextRegisterError {
            self.nextRegisterError = nil
            registeredCombo = nil
            lastTrigger = nil
            throw nextRegisterError
        }
        registeredCombo = combo
        lastTrigger = onTrigger
    }

    func unregister() {
        unregisterCallCount += 1
        registeredCombo = nil
        lastTrigger = nil
    }

    /// Simulate the user pressing the registered combo.
    func fireTrigger() {
        lastTrigger?()
    }
}
