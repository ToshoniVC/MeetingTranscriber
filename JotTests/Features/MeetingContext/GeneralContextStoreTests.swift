import Testing
import Foundation
@testable import Jot

/// Unit + integration coverage for `GeneralContext` (tolerant decoding) and
/// `GeneralContextStore` (default load, persistence round-trip, partial
/// updates). Each store test points at a throwaway temp file so nothing
/// touches the real Application Support profile.
struct GeneralContextStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-general-context-\(UUID().uuidString).json")
    }

    // MARK: - Model decoding

    @Test
    func generalContext_defaultInit_usesDefaultWrapperPrefix() {
        let gc = GeneralContext()
        #expect(gc.wrapperPrefix == ContextCompiler.defaultWrapperPrefix)
        #expect(gc.generalContext.isEmpty)
        #expect(gc.schemaVersion == 1)
    }

    @Test
    func generalContext_decodesMissingFields_toDefaults() throws {
        // A file containing only generalContext — the rest should default.
        let json = #"{ "generalContext": "global terms" }"#.data(using: .utf8)!
        let gc = try JSONDecoder().decode(GeneralContext.self, from: json)
        #expect(gc.generalContext == "global terms")
        #expect(gc.wrapperPrefix == ContextCompiler.defaultWrapperPrefix)
        #expect(gc.schemaVersion == 1)
    }

    @Test
    func generalContext_roundTrips() throws {
        let original = GeneralContext(
            wrapperPrefix: "Lead:",
            generalContext: "Pronounce Niels as 'Nells'.",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            schemaVersion: 1
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeneralContext.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Store

    @MainActor
    @Test
    func store_noFile_loadsDefaults() {
        let store = GeneralContextStore(fileURL: tempURL())
        #expect(store.current.wrapperPrefix == ContextCompiler.defaultWrapperPrefix)
        #expect(store.current.generalContext.isEmpty)
    }

    @MainActor
    @Test
    func store_update_persistsAndReloads() {
        let url = tempURL()
        let store = GeneralContextStore(fileURL: url)
        store.update(wrapperPrefix: "Glossary:", generalContext: "ACME, Niels, Brecht")

        // A fresh store over the same file must see the persisted values.
        let reloaded = GeneralContextStore(fileURL: url)
        #expect(reloaded.current.wrapperPrefix == "Glossary:")
        #expect(reloaded.current.generalContext == "ACME, Niels, Brecht")
    }

    @MainActor
    @Test
    func store_partialUpdate_leavesOtherFieldUntouched() {
        let store = GeneralContextStore(fileURL: tempURL())
        store.update(generalContext: "only general changed")
        #expect(store.current.wrapperPrefix == ContextCompiler.defaultWrapperPrefix)
        #expect(store.current.generalContext == "only general changed")

        store.update(wrapperPrefix: "New lead:")
        #expect(store.current.wrapperPrefix == "New lead:")
        #expect(store.current.generalContext == "only general changed")
    }
}
