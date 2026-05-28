import Testing
import Foundation
@testable import Jot

/// End-to-end tests for `OrganizationStore` against a real on-disk JSON file
/// in a temp directory. Exercises CRUD, the single-default invariant, sort
/// order, and round-trip persistence across "relaunches".
@MainActor
struct OrganizationStoreIntegrationTests {

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-orgs-test-\(UUID().uuidString).json")
    }

    // MARK: - Empty state

    @Test
    func newStore_isEmpty() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)
        #expect(store.organizations.isEmpty)
        #expect(store.defaultOrg() == nil)
    }

    // MARK: - upsert

    @Test
    func upsert_insertsNewOrg() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        try store.upsert(Organization(name: "Acme"))
        #expect(store.organizations.count == 1)
        #expect(store.organizations.first?.name == "Acme")
    }

    @Test
    func upsert_trimsName() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        try store.upsert(Organization(name: "  Acme  "))
        #expect(store.organizations.first?.name == "Acme")
    }

    @Test
    func upsert_updatesExistingByID() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        let acme = try store.upsert(Organization(name: "Acme"))
        var renamed = acme
        renamed.name = "Acme Corp"
        renamed.companyName = "Acme Inc."
        try store.upsert(renamed)

        #expect(store.organizations.count == 1)
        #expect(store.organizations.first?.name == "Acme Corp")
        #expect(store.organizations.first?.companyName == "Acme Inc.")
    }

    @Test
    func upsert_rejectsDuplicateName() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        try store.upsert(Organization(name: "Acme"))
        #expect(throws: OrganizationValidationError.duplicateName("acme")) {
            try store.upsert(Organization(name: "acme"))
        }
        #expect(store.organizations.count == 1)
    }

    @Test
    func upsert_rejectsEmptyName() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        #expect(throws: OrganizationValidationError.emptyName) {
            try store.upsert(Organization(name: "   "))
        }
        #expect(store.organizations.isEmpty)
    }

    // MARK: - delete

    @Test
    func delete_removesOrgByID() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        let acme = try store.upsert(Organization(name: "Acme"))
        try store.upsert(Organization(name: "Beta"))
        store.delete(id: acme.id)

        #expect(store.organizations.count == 1)
        #expect(store.organizations.first?.name == "Beta")
    }

    @Test
    func delete_unknownID_isNoOp() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        try store.upsert(Organization(name: "Acme"))
        store.delete(id: UUID())
        #expect(store.organizations.count == 1)
    }

    // MARK: - default invariant

    @Test
    func setDefault_clearsPreviousDefault() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        let acme = try store.upsert(Organization(name: "Acme", isDefault: true))
        let beta = try store.upsert(Organization(name: "Beta"))
        try store.setDefault(id: beta.id)

        #expect(store.organization(id: acme.id)?.isDefault == false)
        #expect(store.organization(id: beta.id)?.isDefault == true)
        #expect(store.defaultOrg()?.id == beta.id)
    }

    @Test
    func upsert_withDefaultTrue_clearsOtherDefaults() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        let acme = try store.upsert(Organization(name: "Acme", isDefault: true))
        try store.upsert(Organization(name: "Beta", isDefault: true))

        #expect(store.organization(id: acme.id)?.isDefault == false)
        #expect(store.defaultOrg()?.name == "Beta")
    }

    @Test
    func clearDefault_removesDefaultMarker() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        try store.upsert(Organization(name: "Acme", isDefault: true))
        store.clearDefault()
        #expect(store.defaultOrg() == nil)
    }

    @Test
    func setDefault_unknownID_throws() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        let bogus = UUID()
        #expect(throws: OrganizationStoreError.notFound(bogus)) {
            try store.setDefault(id: bogus)
        }
    }

    // MARK: - Sort order

    @Test
    func organizations_sortedDefaultFirstThenAlpha() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OrganizationStore(fileURL: url)

        try store.upsert(Organization(name: "Zebra"))
        try store.upsert(Organization(name: "Acme"))
        try store.upsert(Organization(name: "Mango", isDefault: true))

        let names = store.organizations.map(\.name)
        #expect(names == ["Mango", "Acme", "Zebra"])
    }

    // MARK: - Persistence across instances

    @Test
    func organizations_persistAcrossInstances() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var savedID = UUID()
        do {
            let store = OrganizationStore(fileURL: url)
            let acme = try store.upsert(Organization(
                name: "Acme",
                companyName: "Acme Holdings",
                staffNames: ["Alice", "Bob"],
                isDefault: true
            ))
            savedID = acme.id
        }

        let reborn = OrganizationStore(fileURL: url)
        #expect(reborn.organizations.count == 1)
        let restored = reborn.organization(id: savedID)
        #expect(restored?.name == "Acme")
        #expect(restored?.companyName == "Acme Holdings")
        #expect(restored?.staffNames == ["Alice", "Bob"])
        #expect(restored?.isDefault == true)
    }

    @Test
    func deletePersists() throws {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = OrganizationStore(fileURL: url)
            let acme = try store.upsert(Organization(name: "Acme"))
            try store.upsert(Organization(name: "Beta"))
            store.delete(id: acme.id)
        }

        let reborn = OrganizationStore(fileURL: url)
        #expect(reborn.organizations.count == 1)
        #expect(reborn.organizations.first?.name == "Beta")
    }
}
