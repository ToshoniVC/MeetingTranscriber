import Testing
import Foundation
@testable import Jot

/// Tests for the `KeychainStorage` protocol via the in-memory fake.
///
/// We deliberately do NOT test the production `Keychain` struct against the
/// real macOS Keychain in unit tests — that's stateful, can prompt the user,
/// and varies by signing identity. The `Keychain` type itself is exercised
/// by hand at runtime and by integration tests in later phases.
struct KeychainStorageContractTests {

    @Test
    func set_then_get_returnsValue() throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("sk-test-abc", forKey: "api_key")
        #expect(keychain.getString(forKey: "api_key") == "sk-test-abc")
    }

    @Test
    func get_unknownKey_returnsNil() {
        let keychain = InMemoryKeychain()
        #expect(keychain.getString(forKey: "missing") == nil)
    }

    @Test
    func set_overwritesExistingValue() throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("first", forKey: "api_key")
        try keychain.setString("second", forKey: "api_key")
        #expect(keychain.getString(forKey: "api_key") == "second")
    }

    @Test
    func delete_removesValue() throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("sk-test", forKey: "api_key")
        try keychain.deleteString(forKey: "api_key")
        #expect(keychain.getString(forKey: "api_key") == nil)
    }

    @Test
    func delete_missingKey_doesNotThrow() {
        let keychain = InMemoryKeychain()
        // Behavior matches production `Keychain`: deleting an absent key is
        // not an error — the post-condition is satisfied either way.
        #expect(throws: Never.self) {
            try keychain.deleteString(forKey: "never-existed")
        }
    }

    @Test
    func set_propagatesInjectedError() {
        let keychain = InMemoryKeychain()
        keychain.nextSetError = .unhandled(status: -25300)
        #expect(throws: KeychainError.self) {
            try keychain.setString("anything", forKey: "api_key")
        }
        // After throwing once, the queued error is cleared.
        #expect(throws: Never.self) {
            try keychain.setString("anything", forKey: "api_key")
        }
    }

    @Test
    func separateKeys_areIndependent() throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("apiKeyValue", forKey: "api_key")
        try keychain.setString("otherValue", forKey: "other_secret")
        #expect(keychain.getString(forKey: "api_key") == "apiKeyValue")
        #expect(keychain.getString(forKey: "other_secret") == "otherValue")
        try keychain.deleteString(forKey: "api_key")
        #expect(keychain.getString(forKey: "other_secret") == "otherValue")
    }
}
