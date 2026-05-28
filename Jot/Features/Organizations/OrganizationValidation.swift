import Foundation

/// Pure validation + invariant-maintenance helpers for organization records.
/// Kept free of `Store` knowledge so they can be unit-tested in isolation
/// and called from anywhere (form-level validation in the UI, store-level
/// enforcement on mutation).
enum OrganizationValidation {

    /// Trimmed-empty names are rejected; duplicates are rejected
    /// case-insensitively. The candidate may already exist in `existing`
    /// (an update against itself) — its own id is excluded from the
    /// duplicate check.
    static func validateName(
        _ rawName: String,
        forID candidateID: UUID,
        against existing: [Organization]
    ) throws {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OrganizationValidationError.emptyName }

        let collision = existing.contains { other in
            other.id != candidateID
                && other.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if collision { throw OrganizationValidationError.duplicateName(trimmed) }
    }

    /// Returns `existing` with `isDefault` cleared on every record other
    /// than `winner`. If `winner.isDefault == false` this is a no-op aside
    /// from passing `winner` itself through. Pure — caller writes the
    /// result back.
    static func enforceSingleDefault(
        after winner: Organization,
        in existing: [Organization]
    ) -> [Organization] {
        guard winner.isDefault else { return existing }
        return existing.map { org in
            guard org.id != winner.id, org.isDefault else { return org }
            var demoted = org
            demoted.isDefault = false
            demoted.updatedAt = Date()
            return demoted
        }
    }
}

/// Typed errors thrown by `OrganizationValidation` and surfaced by the
/// store on rejected mutations. UI catches these to render inline messages
/// under the offending field.
enum OrganizationValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Organization name can't be empty."
        case .duplicateName(let name):
            return "An organization named \"\(name)\" already exists."
        }
    }
}
