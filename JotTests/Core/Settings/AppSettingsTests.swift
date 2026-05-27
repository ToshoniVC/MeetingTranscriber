import Testing
import Foundation
import AppKit
@testable import Jot

/// Unit tests for `AppSettings` — focused on the in-memory behavior of the
/// model (`didSet` autosave, defaults, Keychain delegation). Round-trip
/// persistence is exercised by `AppSettingsIntegrationTests`.
@MainActor
struct AppSettingsTests {

    // MARK: - Defaults

    @Test
    func init_withEmptyDefaults_setsAllToDefaults() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()

        let settings = AppSettings(defaults: defaults, keychain: keychain)

        #expect(settings.apiBaseURL == "")
        #expect(settings.modelString == "")
        #expect(settings.watchFolderBookmark == nil)
        #expect(settings.outputFolderBookmark == nil)
        #expect(settings.recordingHotkey == nil)
        #expect(settings.launchOnStartup == false)
        #expect(settings.apiKey == nil)
    }

    // MARK: - Mutation persists via didSet

    @Test
    func setApiBaseURL_persistsToDefaults() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())

        settings.apiBaseURL = "https://api.groq.com/openai/v1/audio/transcriptions"

        #expect(defaults.string(forKey: "jot.settings.apiBaseURL")
                == "https://api.groq.com/openai/v1/audio/transcriptions")
    }

    @Test
    func setLaunchOnStartup_persistsToDefaults() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())

        settings.launchOnStartup = true
        #expect(defaults.bool(forKey: "jot.settings.launchOnStartup") == true)
        settings.launchOnStartup = false
        #expect(defaults.bool(forKey: "jot.settings.launchOnStartup") == false)
    }

    @Test
    func setRecordingHotkey_persistsAsJSON() throws {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())

        let combo = KeyCombo(keyCode: 15, modifierFlags: [.command, .shift])
        settings.recordingHotkey = combo

        let stored = try #require(defaults.data(forKey: "jot.settings.recordingHotkey"))
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: stored)
        #expect(decoded == combo)
    }

    @Test
    func setRecordingHotkey_toNil_removesDefaultsKey() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())

        settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
        #expect(defaults.data(forKey: "jot.settings.recordingHotkey") != nil)
        settings.recordingHotkey = nil
        #expect(defaults.data(forKey: "jot.settings.recordingHotkey") == nil)
    }

    @Test
    func setWatchFolderBookmark_persistsRawData() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())

        let bookmark = Data([0x01, 0x02, 0x03])
        settings.watchFolderBookmark = bookmark
        #expect(defaults.data(forKey: "jot.settings.watchFolderBookmark") == bookmark)
    }

    // MARK: - Keychain-backed apiKey

    @Test
    func setApiKey_writesToKeychain() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )

        settings.apiKey = "sk-test-123"
        #expect(keychain.getString(forKey: AppSettings.apiKeyAccount) == "sk-test-123")
    }

    @Test
    func setApiKey_toEmptyString_deletesFromKeychain() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )

        settings.apiKey = "sk-test-123"
        settings.apiKey = ""
        #expect(keychain.getString(forKey: AppSettings.apiKeyAccount) == nil)
    }

    @Test
    func setApiKey_toNil_deletesFromKeychain() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )

        settings.apiKey = "sk-test-123"
        settings.apiKey = nil
        #expect(keychain.getString(forKey: AppSettings.apiKeyAccount) == nil)
    }

    @Test
    func getApiKey_returnsValueFromKeychain() throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("pre-seeded-key", forKey: AppSettings.apiKeyAccount)
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )
        #expect(settings.apiKey == "pre-seeded-key")
    }

    // MARK: - apiKey is NEVER in UserDefaults

    @Test
    func setApiKey_doesNotTouchUserDefaults() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())

        settings.apiKey = "sk-this-must-not-leak"

        // Walk every key in UserDefaults and verify the secret is nowhere in it.
        for key in defaults.dictionaryRepresentation().keys {
            let value = defaults.object(forKey: key)
            if let string = value as? String {
                #expect(string != "sk-this-must-not-leak", "API key leaked into UserDefaults under \(key)")
            }
            if let data = value as? Data, let asString = String(data: data, encoding: .utf8) {
                #expect(asString != "sk-this-must-not-leak", "API key leaked into UserDefaults as Data under \(key)")
            }
        }
    }
}
