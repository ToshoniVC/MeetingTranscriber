import Foundation
import Security

/// Protocol abstracting Keychain access so tests can substitute an in-memory
/// fake (see `JotTests/Helpers/InMemoryKeychain.swift`). The production type
/// `Keychain` below implements it via `SecItem*` APIs.
///
/// Per Claude/coding-instructions.md §3 (Secrets), the API key never lives in
/// `UserDefaults`, on disk in plaintext, or in git. The only sanctioned home
/// is the macOS Keychain accessed through this protocol.
protocol KeychainStorage: Sendable {
    func setString(_ value: String, forKey key: String) throws
    func getString(forKey key: String) -> String?
    func deleteString(forKey key: String) throws
}

/// Errors surfaced by the production `Keychain`. The status code is included
/// so logs and tests can pin down what `SecItem*` reported.
enum KeychainError: Error, Equatable {
    case unexpectedData
    case unhandled(status: OSStatus)
}

/// Production Keychain wrapper.
///
/// Uses a single service identifier (`com.toshonivc.jot` for the production
/// build, `com.toshonivc.jot.dev` for Debug — passed in by `AppSettings`),
/// with the *account* field varying per stored secret. Phase 1 only stores
/// the API key (`account = "api_key"`); later phases can store more by
/// reusing the same instance with a different `account` argument.
struct Keychain: KeychainStorage {
    let service: String

    init(service: String) {
        self.service = service
    }

    func setString(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        // Try to update an existing item first; fall back to add if absent.
        // This avoids the `errSecDuplicateItem` we'd get from a blind add.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            // Add new entry
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Restrict to this device — never sync to iCloud Keychain.
            addQuery[kSecAttrSynchronizable as String] = false
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(status: addStatus)
            }
        default:
            throw KeychainError.unhandled(status: updateStatus)
        }
    }

    func getString(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }

        return string
    }

    func deleteString(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        // Deleting a key that isn't there is not an error from the caller's
        // perspective — the post-condition (key not present) is satisfied.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status: status)
        }
    }
}
