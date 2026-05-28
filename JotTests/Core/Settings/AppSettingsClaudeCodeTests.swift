import Testing
import Foundation
@testable import Jot

/// Unit tests for the Claude Code routine fields on `AppSettings`. Mirrors
/// `AppSettingsNotionTests` — toggle + endpoint + extra text round-trip
/// through UserDefaults; bearer token round-trips through the injected
/// Keychain fake and never touches UserDefaults.
@MainActor
struct AppSettingsClaudeCodeTests {

    // MARK: - Defaults

    @Test
    func init_withEmptyDefaults_setsClaudeCodeFieldsToDefaults() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()

        let settings = AppSettings(defaults: defaults, keychain: keychain)

        #expect(settings.claudeCodeNotesEnabled == false)
        #expect(settings.claudeCodeEndpoint == "")
        #expect(settings.claudeCodeExtraText == "")
        #expect(settings.claudeCodeToken == nil)
    }

    // MARK: - claudeCodeNotesEnabled

    @Test
    func setClaudeCodeNotesEnabled_persistsAndRoundTrips() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()
        do {
            let settings = AppSettings(defaults: defaults, keychain: keychain)
            settings.claudeCodeNotesEnabled = true
            #expect(defaults.bool(forKey: "jot.settings.claudeCodeNotesEnabled") == true)
        }
        let reborn = AppSettings(defaults: defaults, keychain: keychain)
        #expect(reborn.claudeCodeNotesEnabled == true)
    }

    // MARK: - claudeCodeEndpoint

    @Test
    func setClaudeCodeEndpoint_persistsAndRoundTrips() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()
        do {
            let settings = AppSettings(defaults: defaults, keychain: keychain)
            settings.claudeCodeEndpoint = "https://api.anthropic.com/v1/claude_code/routines/trg_123/fire"
            #expect(defaults.string(forKey: "jot.settings.claudeCodeEndpoint")
                    == "https://api.anthropic.com/v1/claude_code/routines/trg_123/fire")
        }
        let reborn = AppSettings(defaults: defaults, keychain: keychain)
        #expect(reborn.claudeCodeEndpoint
                == "https://api.anthropic.com/v1/claude_code/routines/trg_123/fire")
    }

    // MARK: - claudeCodeExtraText

    @Test
    func setClaudeCodeExtraText_persistsAndRoundTrips() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let keychain = InMemoryKeychain()
        do {
            let settings = AppSettings(defaults: defaults, keychain: keychain)
            settings.claudeCodeExtraText = "Please write detailed action items."
            #expect(defaults.string(forKey: "jot.settings.claudeCodeExtraText")
                    == "Please write detailed action items.")
        }
        let reborn = AppSettings(defaults: defaults, keychain: keychain)
        #expect(reborn.claudeCodeExtraText == "Please write detailed action items.")
    }

    // MARK: - claudeCodeToken (Keychain-backed)

    @Test
    func setClaudeCodeToken_writesToKeychain() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )
        settings.claudeCodeToken = "anthropic-bearer-token"
        #expect(keychain.getString(forKey: AppSettings.claudeCodeTokenAccount) == "anthropic-bearer-token")
    }

    @Test
    func setClaudeCodeToken_toEmptyString_deletesFromKeychain() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )
        settings.claudeCodeToken = "anthropic-bearer-token"
        settings.claudeCodeToken = ""
        #expect(keychain.getString(forKey: AppSettings.claudeCodeTokenAccount) == nil)
    }

    @Test
    func setClaudeCodeToken_toNil_deletesFromKeychain() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )
        settings.claudeCodeToken = "anthropic-bearer-token"
        settings.claudeCodeToken = nil
        #expect(keychain.getString(forKey: AppSettings.claudeCodeTokenAccount) == nil)
    }

    @Test
    func getClaudeCodeToken_returnsValueFromKeychain() throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("seeded-cc-token", forKey: AppSettings.claudeCodeTokenAccount)
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )
        #expect(settings.claudeCodeToken == "seeded-cc-token")
    }

    // MARK: - claudeCodeToken does NOT leak into UserDefaults

    @Test
    func setClaudeCodeToken_doesNotTouchUserDefaults() {
        let defaults = EphemeralUserDefaults.make()
        defer { EphemeralUserDefaults.tearDown(defaults) }
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())

        settings.claudeCodeToken = "cc-secret-must-not-leak"

        for key in defaults.dictionaryRepresentation().keys {
            let value = defaults.object(forKey: key)
            if let string = value as? String {
                #expect(string != "cc-secret-must-not-leak", "Claude Code token leaked into UserDefaults under \(key)")
            }
            if let data = value as? Data, let asString = String(data: data, encoding: .utf8) {
                #expect(asString != "cc-secret-must-not-leak", "Claude Code token leaked into UserDefaults as Data under \(key)")
            }
        }
    }

    // MARK: - Independence from other secrets

    @Test
    func claudeCodeToken_isIndependentFromOtherTokens() {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            defaults: EphemeralUserDefaults.make(),
            keychain: keychain
        )

        settings.apiKey = "groq-key"
        settings.notionToken = "notion-secret"
        settings.claudeCodeToken = "claude-code-secret"

        #expect(keychain.getString(forKey: AppSettings.apiKeyAccount) == "groq-key")
        #expect(keychain.getString(forKey: AppSettings.notionTokenAccount) == "notion-secret")
        #expect(keychain.getString(forKey: AppSettings.claudeCodeTokenAccount) == "claude-code-secret")

        // Deleting one must not touch the others.
        settings.claudeCodeToken = nil
        #expect(keychain.getString(forKey: AppSettings.apiKeyAccount) == "groq-key")
        #expect(keychain.getString(forKey: AppSettings.notionTokenAccount) == "notion-secret")
        #expect(keychain.getString(forKey: AppSettings.claudeCodeTokenAccount) == nil)
    }
}
