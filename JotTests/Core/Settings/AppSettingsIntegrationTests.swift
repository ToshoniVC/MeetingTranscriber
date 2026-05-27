import Testing
import Foundation
import AppKit
@testable import Jot

/// Integration tests for `AppSettings`: write everything, simulate relaunch
/// by tearing down the model and re-instantiating from the same backing
/// `UserDefaults` + `InMemoryKeychain`, and verify the full surface
/// round-trips. This is the §6 "integration test" complement to
/// `AppSettingsTests`.
@MainActor
struct AppSettingsIntegrationTests {

    @Test
    func fullSettingsRoundTripAcrossInstances() throws {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()

        // First instance — write everything.
        do {
            let settings = AppSettings(defaults: defaults, keychain: keychain)
            settings.apiBaseURL          = "https://api.openai.com/v1/audio/transcriptions"
            settings.modelString         = "whisper-1"
            settings.apiKey              = "sk-roundtrip-1234"
            settings.watchFolderBookmark = Data([0x10, 0x20, 0x30, 0x40])
            settings.outputFolderBookmark = Data([0xA0, 0xB0, 0xC0, 0xD0])
            settings.recordingHotkey     = KeyCombo(keyCode: 15, modifierFlags: [.command, .shift])
            settings.launchOnStartup     = true
        }

        // Second instance — "relaunch" with the same backing stores.
        let reborn = AppSettings(defaults: defaults, keychain: keychain)

        #expect(reborn.apiBaseURL == "https://api.openai.com/v1/audio/transcriptions")
        #expect(reborn.modelString == "whisper-1")
        #expect(reborn.apiKey == "sk-roundtrip-1234")
        #expect(reborn.watchFolderBookmark == Data([0x10, 0x20, 0x30, 0x40]))
        #expect(reborn.outputFolderBookmark == Data([0xA0, 0xB0, 0xC0, 0xD0]))
        #expect(reborn.recordingHotkey == KeyCombo(keyCode: 15, modifierFlags: [.command, .shift]))
        #expect(reborn.launchOnStartup == true)
    }

    @Test
    func emptyDefaultsRelaunch_stillProducesValidInstance() {
        // Equivalent to a brand-new install. No defaults, no Keychain entries.
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()

        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let validation = SettingsValidator.validate(
            apiBaseURL: settings.apiBaseURL,
            modelString: settings.modelString,
            apiKeyIsPresent: settings.apiKey != nil,
            watchFolderBookmark: settings.watchFolderBookmark,
            outputFolderBookmark: settings.outputFolderBookmark
        )

        // Fresh install is "not yet configured" — we expect every required
        // field to report missing, but no crash and no spurious values.
        #expect(validation.contains(.blankAPIBaseURL))
        #expect(validation.contains(.blankModelString))
        #expect(validation.contains(.missingAPIKey))
        #expect(validation.contains(.missingWatchFolder))
        #expect(validation.contains(.missingOutputFolder))
    }

    @Test
    func clearingHotkey_persistsAsAbsent() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()

        // Set and clear in one instance.
        do {
            let settings = AppSettings(defaults: defaults, keychain: keychain)
            settings.recordingHotkey = KeyCombo(keyCode: 15, modifierFlags: [.command])
            settings.recordingHotkey = nil
        }

        // Verify a fresh instance also sees no hotkey.
        let reborn = AppSettings(defaults: defaults, keychain: keychain)
        #expect(reborn.recordingHotkey == nil)
    }

    @Test
    func clearingApiKey_doesNotLingerInKeychain() {
        let keychain = InMemoryKeychain()
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }

        do {
            let settings = AppSettings(defaults: defaults, keychain: keychain)
            settings.apiKey = "to-be-deleted"
            settings.apiKey = nil
        }

        // Inspect the underlying keychain directly.
        #expect(keychain.getString(forKey: AppSettings.apiKeyAccount) == nil)
        #expect(keychain.keys.isEmpty)
    }
}
