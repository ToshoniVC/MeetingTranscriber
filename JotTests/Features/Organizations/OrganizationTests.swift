import Testing
import Foundation
@testable import Jot

/// Codable round-trip tests for `Organization` and `AcronymEntry`.
struct OrganizationTests {

    @Test
    func roundTrip_minimalOrg_preservesIDAndDefaults() throws {
        let original = Organization(name: "Acme")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Organization.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == "Acme")
        #expect(decoded.companyName == nil)
        #expect(decoded.staffNames.isEmpty)
        #expect(decoded.projectNames.isEmpty)
        #expect(decoded.glossaryTerms.isEmpty)
        #expect(decoded.acronyms.isEmpty)
        #expect(decoded.freeformNotes == nil)
        #expect(decoded.isDefault == false)
        #expect(decoded.schemaVersion == 1)
    }

    @Test
    func roundTrip_fullyPopulatedOrg_preservesEverything() throws {
        let original = Organization(
            name: "Acme",
            companyName: "Acme Holdings",
            staffNames: ["Alice", "Bob"],
            projectNames: ["Phoenix", "Sparrow"],
            glossaryTerms: ["UX", "ARR"],
            acronyms: [
                AcronymEntry(term: "MRR", expansion: "Monthly Recurring Revenue"),
                AcronymEntry(term: "CAC", expansion: "Customer Acquisition Cost"),
            ],
            freeformNotes: "Pronounce 'Phoenix' /ˈfiːnɪks/.",
            isDefault: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Organization.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func acronymEntry_isCodable() throws {
        let original = AcronymEntry(term: "ARPU", expansion: "Average Revenue Per User")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AcronymEntry.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func emptyCollection_decodesAsEmpty() throws {
        let payload = Data("[]".utf8)
        let decoded = try JSONDecoder().decode([Organization].self, from: payload)
        #expect(decoded.isEmpty)
    }
}
