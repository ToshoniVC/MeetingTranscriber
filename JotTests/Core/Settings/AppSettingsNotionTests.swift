import Testing
import Foundation
@testable import Jot

/// Unit tests for the Notion-related fields on `AppSettings` — round-trip
/// behavior for the toggle and database ID through UserDefaults, and for
/// the integration token through the injected Keychain fake. Mirrors the
/// patterns in `AppSettingsTests` for the existing `apiKey` field.
@MainActor
struct AppSettingsNotionTests {

    // MARK: - Defaults

    @Test
    func init_withEmptyDefaults_setsNotionFieldsToDefaults() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()

        let settings = AppSettings(defaults: defaults, keychain: keychain)

        #expect(settings.notionEnabled == false)
        #expect(settings.notionDatabaseId == "")
        #expect(settings.notionToken == nil)
    }

    // MARK: - notionEnabled

    @Test
    func setNotionEnabled_persistsAndRoundTrips() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()
        do {
            let settings = AppSettings(defaults: defaults, keychain: keychain)
            settings.notionEnabled = true
            #expect(defaults.bool(forKey: "jot.settings.notionEnabled") == true)
        }
        let reborn = AppSettings(defaults: defaults, keychain: keychain)
        #expect(reborn.notionEnabled == true)
    }

    // MARK: - notionDatabaseId

    @Test
    func setNotionDatabaseId_persistsAndRoundTrips() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()
        do {
            let settings = AppSettings(defaults: defaults, keychain: keychain)
            settings.notionDatabaseId = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"
            #expect(defaults.string(forKey: "jot.settings.notionDatabaseId")
                    == "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")
        }
        let reborn = AppSettings(defaults: defaults, keychain: keychain)
        #expect(reborn.notionDatabaseId == "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")
    }

    // MARK: - notionToken (Keychain-backed)

    @Test
    func setNotionToken_writesToKeychain() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )

        settings.notionToken = "secret_abc123"

        #expect(keychain.getString(forKey: AppSettings.notionTokenAccount) == "secret_abc123")
    }

    @Test
    func setNotionToken_toEmptyString_deletesFromKeychain() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )

        settings.notionToken = "secret_abc123"
        settings.notionToken = ""
        #expect(keychain.getString(forKey: AppSettings.notionTokenAccount) == nil)
    }

    @Test
    func setNotionToken_toNil_deletesFromKeychain() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )

        settings.notionToken = "secret_abc123"
        settings.notionToken = nil
        #expect(keychain.getString(forKey: AppSettings.notionTokenAccount) == nil)
    }

    @Test
    func getNotionToken_returnsValueFromKeychain() throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("seeded-notion-token", forKey: AppSettings.notionTokenAccount)
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )
        #expect(settings.notionToken == "seeded-notion-token")
    }

    // MARK: - notionToken does NOT leak into UserDefaults

    @Test
    func setNotionToken_doesNotTouchUserDefaults() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())

        settings.notionToken = "secret-this-must-not-leak"

        for key in defaults.dictionaryRepresentation().keys {
            let value = defaults.object(forKey: key)
            if let string = value as? String {
                #expect(string != "secret-this-must-not-leak", "Notion token leaked into UserDefaults under \(key)")
            }
            if let data = value as? Data, let asString = String(data: data, encoding: .utf8) {
                #expect(asString != "secret-this-must-not-leak", "Notion token leaked into UserDefaults as Data under \(key)")
            }
        }
    }

    // MARK: - Independence from apiKey

    @Test
    func notionToken_andApiKey_useDifferentKeychainAccounts() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )

        settings.apiKey = "groq-key"
        settings.notionToken = "notion-secret"

        #expect(keychain.getString(forKey: AppSettings.apiKeyAccount) == "groq-key")
        #expect(keychain.getString(forKey: AppSettings.notionTokenAccount) == "notion-secret")

        // Deleting one must not touch the other.
        settings.apiKey = nil
        #expect(keychain.getString(forKey: AppSettings.apiKeyAccount) == nil)
        #expect(keychain.getString(forKey: AppSettings.notionTokenAccount) == "notion-secret")
    }
}
