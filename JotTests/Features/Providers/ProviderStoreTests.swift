import Testing
import Foundation
@testable import Jot

/// Unit/integration tests for `ProviderStore`. Each test uses a fresh
/// tmpdir JSON URL + an `InMemoryKeychain` so they're hermetic and
/// don't touch the user's real Keychain or Application Support files.
@MainActor
struct ProviderStoreTests {

    private static func makeStore() -> (ProviderStore, InMemoryKeychain, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-provider-test-\(UUID().uuidString).json")
        let keychain = InMemoryKeychain()
        let store = ProviderStore(fileURL: url, keychain: keychain)
        return (store, keychain, url)
    }

    private static func sampleProvider(name: String = "OpenAI") -> Provider {
        Provider(
            displayName: name,
            baseURL: "https://api.\(name.lowercased()).com/v1/audio/transcriptions",
            model: "whisper-1"
        )
    }

    // MARK: - upsert

    @Test
    func upsert_addsNewProvider() throws {
        let (store, _, _) = Self.makeStore()
        _ = try store.upsert(Self.sampleProvider())
        #expect(store.providers.count == 1)
        #expect(store.providers.first?.displayName == "OpenAI")
    }

    @Test
    func upsert_trimsWhitespaceOnSave() throws {
        let (store, _, _) = Self.makeStore()
        var p = Self.sampleProvider()
        p.displayName = "  OpenAI  "
        p.baseURL = "  https://example.com/  "
        p.model = "  whisper-1  "
        let saved = try store.upsert(p)
        #expect(saved.displayName == "OpenAI")
        #expect(saved.baseURL == "https://example.com/")
        #expect(saved.model == "whisper-1")
    }

    @Test
    func upsert_updatesExistingById() throws {
        let (store, _, _) = Self.makeStore()
        var p = Self.sampleProvider()
        _ = try store.upsert(p)
        p.model = "whisper-large-v3"
        _ = try store.upsert(p)
        #expect(store.providers.count == 1)
        #expect(store.providers.first?.model == "whisper-large-v3")
    }

    @Test
    func upsert_newProviderGetsBottomSortOrder() throws {
        let (store, _, _) = Self.makeStore()
        _ = try store.upsert(Self.sampleProvider(name: "OpenAI"))
        // Second one with default sortOrder=0 should auto-bump to land last.
        _ = try store.upsert(Self.sampleProvider(name: "Groq"))
        let ordered = store.providers.sorted { $0.sortOrder < $1.sortOrder }
        #expect(ordered.map(\.displayName) == ["OpenAI", "Groq"])
    }

    @Test
    func upsert_duplicateNameThrows() throws {
        let (store, _, _) = Self.makeStore()
        _ = try store.upsert(Self.sampleProvider(name: "OpenAI"))
        #expect(throws: ProviderValidationError.self) {
            _ = try store.upsert(Self.sampleProvider(name: "openai")) // diff case
        }
    }

    // MARK: - delete

    @Test
    func delete_removesProviderAndKey() throws {
        let (store, keychain, _) = Self.makeStore()
        let p = try store.upsert(Self.sampleProvider())
        store.setAPIKey("sk-test", for: p)
        #expect(keychain.getString(forKey: p.keychainAccount) == "sk-test")

        store.delete(id: p.id)
        #expect(store.providers.isEmpty)
        #expect(keychain.getString(forKey: p.keychainAccount) == nil)
    }

    // MARK: - reorder

    @Test
    func reorder_rewritesSortOrderToMatchIDList() throws {
        let (store, _, _) = Self.makeStore()
        let a = try store.upsert(Self.sampleProvider(name: "A"))
        let b = try store.upsert(Self.sampleProvider(name: "B"))
        let c = try store.upsert(Self.sampleProvider(name: "C"))

        store.reorder(toIDs: [c.id, a.id, b.id])

        let ordered = store.providers.sorted { $0.sortOrder < $1.sortOrder }
        #expect(ordered.map(\.displayName) == ["C", "A", "B"])
    }

    // MARK: - enabledOrdered

    @Test
    func enabledOrdered_excludesDisabled() throws {
        let (store, _, _) = Self.makeStore()
        let a = try store.upsert(Self.sampleProvider(name: "A"))
        _ = try store.upsert(Self.sampleProvider(name: "B"))
        let c = try store.upsert(Self.sampleProvider(name: "C"))

        // Disable B
        var bUpdate = store.provider(id: store.providers[1].id)!
        bUpdate.isEnabled = false
        _ = try store.upsert(bUpdate)

        let names = store.enabledOrdered().map(\.displayName)
        #expect(names == [a.displayName, c.displayName])
    }

    // MARK: - persistence

    @Test
    func reload_fromDisk_preservesProviders() throws {
        let (store, _, url) = Self.makeStore()
        _ = try store.upsert(Self.sampleProvider(name: "OpenAI"))
        _ = try store.upsert(Self.sampleProvider(name: "Groq"))

        // Re-instantiate the store against the same file.
        let reloaded = ProviderStore(fileURL: url, keychain: InMemoryKeychain())
        #expect(reloaded.providers.count == 2)
    }

    // MARK: - API keys

    @Test
    func setAPIKey_writeAndRead() throws {
        let (store, _, _) = Self.makeStore()
        let p = try store.upsert(Self.sampleProvider())
        store.setAPIKey("sk-abcd", for: p)
        #expect(store.apiKey(for: p) == "sk-abcd")
        #expect(store.hasAPIKey(for: p))
    }

    @Test
    func setAPIKey_nilClears() throws {
        let (store, _, _) = Self.makeStore()
        let p = try store.upsert(Self.sampleProvider())
        store.setAPIKey("sk-abcd", for: p)
        store.setAPIKey(nil, for: p)
        #expect(store.apiKey(for: p) == nil)
    }

    // MARK: - readiness

    @Test
    func readiness_reflectsKeyAndEnabled() throws {
        let (store, _, _) = Self.makeStore()
        var p = try store.upsert(Self.sampleProvider())
        #expect(store.readiness(of: p) == .missingKey)

        store.setAPIKey("sk-test", for: p)
        #expect(store.readiness(of: p) == .ready)

        p.isEnabled = false
        _ = try store.upsert(p)
        #expect(store.readiness(of: p) == .disabled)
    }
}
