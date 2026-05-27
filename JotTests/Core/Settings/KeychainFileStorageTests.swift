import Testing
import Foundation
@testable import Jot

/// Integration tests for the production `Keychain` (file-backed). Each test
/// uses a unique temp file so they're hermetic and parallel-safe.
struct KeychainFileStorageTests {

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-keychain-test-\(UUID().uuidString).json")
    }

    @Test
    func roundTripsValue() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = Keychain(service: "test", fileURL: url)

        try keychain.setString("sk-test-123", forKey: "api_key")
        #expect(keychain.getString(forKey: "api_key") == "sk-test-123")
    }

    @Test
    func unknownKey_returnsNil() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = Keychain(service: "test", fileURL: url)
        #expect(keychain.getString(forKey: "never_set") == nil)
    }

    @Test
    func setOverwritesPreviousValue() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = Keychain(service: "test", fileURL: url)

        try keychain.setString("first", forKey: "api_key")
        try keychain.setString("second", forKey: "api_key")
        #expect(keychain.getString(forKey: "api_key") == "second")
    }

    @Test
    func deleteRemovesKey() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = Keychain(service: "test", fileURL: url)

        try keychain.setString("to-delete", forKey: "api_key")
        try keychain.deleteString(forKey: "api_key")
        #expect(keychain.getString(forKey: "api_key") == nil)
    }

    @Test
    func deleteMissingKey_doesNotThrow() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = Keychain(service: "test", fileURL: url)
        #expect(throws: Never.self) {
            try keychain.deleteString(forKey: "never_existed")
        }
    }

    @Test
    func valuePersistsAcrossInstances() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let keychain = Keychain(service: "test", fileURL: url)
            try keychain.setString("persisted", forKey: "api_key")
        }
        let reborn = Keychain(service: "test", fileURL: url)
        #expect(reborn.getString(forKey: "api_key") == "persisted")
    }

    @Test
    func storageFileHasUserOnlyPermissions() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = Keychain(service: "test", fileURL: url)
        try keychain.setString("anything", forKey: "api_key")

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600, "Secrets file must be user-only readable (got \(mode.map { String($0, radix: 8) } ?? "nil"))")
    }

    @Test
    func multipleKeysCoexistInOneFile() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = Keychain(service: "test", fileURL: url)

        try keychain.setString("v1", forKey: "key1")
        try keychain.setString("v2", forKey: "key2")
        try keychain.setString("v3", forKey: "key3")

        #expect(keychain.getString(forKey: "key1") == "v1")
        #expect(keychain.getString(forKey: "key2") == "v2")
        #expect(keychain.getString(forKey: "key3") == "v3")

        try keychain.deleteString(forKey: "key2")
        #expect(keychain.getString(forKey: "key1") == "v1")
        #expect(keychain.getString(forKey: "key2") == nil)
        #expect(keychain.getString(forKey: "key3") == "v3")
    }

    @Test
    func differentServicesUseDifferentDefaultFiles() {
        // Verify the default-URL path includes the service so two services
        // never accidentally share a file.
        let a = Keychain(service: "service-a")
        let b = Keychain(service: "service-b")
        #expect(a.fileURL != b.fileURL)
    }
}
