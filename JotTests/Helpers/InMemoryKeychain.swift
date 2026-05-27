import Foundation
@testable import Jot

/// Test-only fake for `KeychainStorage`. Stores values in a dictionary
/// instead of the real Keychain — so tests don't touch the user's actual
/// Keychain, don't require entitlements, and are fully hermetic.
///
/// Lives under `JotTests/Helpers/` so multiple test files can share it.
final class InMemoryKeychain: KeychainStorage, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    /// Force-throw on the next mutating call, then reset. Lets tests exercise
    /// error paths without complicated mocking machinery.
    var nextSetError: KeychainError?
    var nextDeleteError: KeychainError?

    func setString(_ value: String, forKey key: String) throws {
        if let error = nextSetError {
            nextSetError = nil
            throw error
        }
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    func getString(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func deleteString(forKey key: String) throws {
        if let error = nextDeleteError {
            nextDeleteError = nil
            throw error
        }
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    // MARK: - Test-only inspection

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    var keys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(storage.keys)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
        nextSetError = nil
        nextDeleteError = nil
    }
}
