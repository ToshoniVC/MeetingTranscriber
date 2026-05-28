import Testing
import Foundation
@testable import Jot

/// Tests for the one-way migration from v0.4.4 single-provider settings
/// into a `ProviderStore` entry.
@MainActor
struct LegacyProviderMigrationTests {

    private static func makeSettings(
        apiBaseURL: String,
        model: String,
        apiKey: String?
    ) -> (AppSettings, InMemoryKeychain) {
        let defaults = EphemeralUserDefaults.make()
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        settings.apiBaseURL = apiBaseURL
        settings.modelString = model
        settings.apiKey = apiKey
        return (settings, keychain)
    }

    private static func makeStore(keychain: KeychainStorage) -> (ProviderStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-migration-test-\(UUID().uuidString).json")
        return (ProviderStore(fileURL: url, keychain: keychain), url)
    }

    @Test
    func migrate_fromLegacyOpenAISettings_createsOneEnabledProvider() {
        let (settings, keychain) = Self.makeSettings(
            apiBaseURL: "https://api.openai.com/v1/audio/transcriptions",
            model: "whisper-1",
            apiKey: "sk-test"
        )
        let (store, _) = Self.makeStore(keychain: keychain)

        let outcome = LegacyProviderMigration.migrateIfNeeded(settings: settings, store: store)

        guard case .migrated(let provider) = outcome else {
            Issue.record("Expected .migrated, got \(outcome)")
            return
        }
        #expect(provider.displayName == "OpenAI")
        #expect(provider.isEnabled)
        #expect(provider.sortOrder == 0)
        #expect(store.providers.count == 1)
        #expect(store.apiKey(for: provider) == "sk-test")
    }

    @Test
    func migrate_groqSettings_namesItGroq() {
        let (settings, keychain) = Self.makeSettings(
            apiBaseURL: "https://api.groq.com/openai/v1/audio/transcriptions",
            model: "whisper-large-v3",
            apiKey: "gsk_test"
        )
        let (store, _) = Self.makeStore(keychain: keychain)

        let outcome = LegacyProviderMigration.migrateIfNeeded(settings: settings, store: store)

        if case .migrated(let p) = outcome {
            #expect(p.displayName == "Groq")
            #expect(p.model == "whisper-large-v3")
        } else {
            Issue.record("Expected .migrated")
        }
    }

    @Test
    func migrate_isIdempotent_secondCallIsNoop() {
        let (settings, keychain) = Self.makeSettings(
            apiBaseURL: "https://api.openai.com/v1/audio/transcriptions",
            model: "whisper-1",
            apiKey: "sk-test"
        )
        let (store, _) = Self.makeStore(keychain: keychain)

        _ = LegacyProviderMigration.migrateIfNeeded(settings: settings, store: store)
        let outcome2 = LegacyProviderMigration.migrateIfNeeded(settings: settings, store: store)

        #expect(outcome2 == .alreadyMigrated)
        #expect(store.providers.count == 1)
    }

    @Test
    func migrate_noLegacyData_returnsNoLegacyData() {
        let (settings, keychain) = Self.makeSettings(apiBaseURL: "", model: "", apiKey: nil)
        let (store, _) = Self.makeStore(keychain: keychain)

        let outcome = LegacyProviderMigration.migrateIfNeeded(settings: settings, store: store)
        #expect(outcome == .noLegacyData)
        #expect(store.providers.isEmpty)
    }

    @Test
    func migrate_partialLegacyData_returnsNoLegacyData() {
        // Has URL + model but no key → not migratable (the resulting
        // provider would be incomplete).
        let (settings, keychain) = Self.makeSettings(
            apiBaseURL: "https://api.openai.com/v1/audio/transcriptions",
            model: "whisper-1",
            apiKey: nil
        )
        let (store, _) = Self.makeStore(keychain: keychain)

        let outcome = LegacyProviderMigration.migrateIfNeeded(settings: settings, store: store)
        #expect(outcome == .noLegacyData)
    }
}
