import Testing
import Foundation
@testable import Jot

/// Pure-logic tests for name validation and the single-default invariant.
struct OrganizationValidationTests {

    // MARK: - validateName

    @Test
    func validateName_acceptsNonEmptyUniqueName() {
        let id = UUID()
        #expect(throws: Never.self) {
            try OrganizationValidation.validateName(
                "Acme", forID: id, against: []
            )
        }
    }

    @Test
    func validateName_rejectsEmpty() {
        #expect(throws: OrganizationValidationError.emptyName) {
            try OrganizationValidation.validateName(
                "", forID: UUID(), against: []
            )
        }
    }

    @Test
    func validateName_rejectsWhitespaceOnly() {
        #expect(throws: OrganizationValidationError.emptyName) {
            try OrganizationValidation.validateName(
                "   \n\t ", forID: UUID(), against: []
            )
        }
    }

    @Test
    func validateName_rejectsDuplicateCaseInsensitively() {
        let existing = [Organization(name: "Acme")]
        #expect(throws: OrganizationValidationError.duplicateName("acme")) {
            try OrganizationValidation.validateName(
                "acme", forID: UUID(), against: existing
            )
        }
    }

    @Test
    func validateName_allowsSameNameOnSelf() {
        let acme = Organization(name: "Acme")
        // Updating Acme to keep its own name should not trip the duplicate check.
        #expect(throws: Never.self) {
            try OrganizationValidation.validateName(
                "Acme", forID: acme.id, against: [acme]
            )
        }
    }

    // MARK: - enforceSingleDefault

    @Test
    func enforceSingleDefault_clearsPreviousDefault() {
        let oldDefault = Organization(name: "Old", isDefault: true)
        let other = Organization(name: "Other", isDefault: false)
        let winner = Organization(name: "New", isDefault: true)

        let result = OrganizationValidation.enforceSingleDefault(
            after: winner, in: [oldDefault, other, winner]
        )

        // Old default should have isDefault cleared.
        let oldUpdated = result.first { $0.id == oldDefault.id }
        #expect(oldUpdated?.isDefault == false)
        // The other non-default stays the same.
        let otherUpdated = result.first { $0.id == other.id }
        #expect(otherUpdated?.isDefault == false)
        // Winner keeps default.
        let winnerUpdated = result.first { $0.id == winner.id }
        #expect(winnerUpdated?.isDefault == true)
    }

    @Test
    func enforceSingleDefault_winnerNotDefault_isNoOp() {
        let existingDefault = Organization(name: "Existing", isDefault: true)
        let loser = Organization(name: "Loser", isDefault: false)

        let result = OrganizationValidation.enforceSingleDefault(
            after: loser, in: [existingDefault, loser]
        )

        // existing default should not be touched
        let existing = result.first { $0.id == existingDefault.id }
        #expect(existing?.isDefault == true)
    }

    @Test
    func enforceSingleDefault_noPreviousDefault_leavesListAlone() {
        let a = Organization(name: "A", isDefault: false)
        let b = Organization(name: "B", isDefault: true)

        let result = OrganizationValidation.enforceSingleDefault(
            after: b, in: [a, b]
        )

        #expect(result.first(where: { $0.id == a.id })?.isDefault == false)
        #expect(result.first(where: { $0.id == b.id })?.isDefault == true)
    }
}
