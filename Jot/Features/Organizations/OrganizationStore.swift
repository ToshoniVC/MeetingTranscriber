import Foundation
import Observation

/// Persistent store of `Organization` records backing the Context tab.
///
/// Mirrors the `AuditLogStore` / `MeetingNameStore` pattern: `@MainActor`
/// + `@Observable` so SwiftUI views bind directly; lazy load on init;
/// persist atomically on every mutation; per-bundle storage so Jot and
/// Jot Dev have independent profiles.
///
/// **Storage location:** `Application Support/<bundleName>/organizations.json`.
///
/// **Default-org invariant.** At most one organization has `isDefault == true`
/// at any time. The store enforces this on every `upsert(_:)` and
/// `setDefault(id:)`; clients don't need to clear the previous default
/// themselves.
@MainActor
@Observable
final class OrganizationStore {

    /// Current snapshot, sorted with the default org first, then the rest
    /// alphabetically (case-insensitive). SwiftUI binds to this directly.
    private(set) var organizations: [Organization] = []

    private let fileURL: URL
    private var loaded = false

    init(fileURL: URL = OrganizationStore.defaultURL()) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Public API

    /// Look up by id. `nil` if the org has been deleted.
    func organization(id: UUID) -> Organization? {
        organizations.first { $0.id == id }
    }

    /// The currently-default organization, if any. `nil` if no org is
    /// marked default (which includes the no-orgs case).
    func defaultOrg() -> Organization? {
        organizations.first(where: \.isDefault)
    }

    /// Insert a new org or update an existing one (matched by `id`).
    /// Validates the name (non-empty, unique case-insensitively against
    /// the other records). Re-stamps `updatedAt`. Enforces the
    /// single-default invariant.
    @discardableResult
    func upsert(_ org: Organization) throws -> Organization {
        try OrganizationValidation.validateName(
            org.name, forID: org.id, against: organizations
        )

        var next = org
        next.name = org.name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.updatedAt = Date()

        var updated = organizations
        if let idx = updated.firstIndex(where: { $0.id == org.id }) {
            updated[idx] = next
        } else {
            updated.append(next)
        }
        updated = OrganizationValidation.enforceSingleDefault(after: next, in: updated)
        organizations = sorted(updated)
        persist()
        return next
    }

    /// Delete the org with `id`. No-op if it doesn't exist. If the deleted
    /// org was the default, no replacement is auto-promoted — clients can
    /// pick a new default explicitly via `setDefault(id:)`.
    func delete(id: UUID) {
        let before = organizations.count
        organizations.removeAll { $0.id == id }
        if organizations.count != before {
            persist()
        }
    }

    /// Mark the org with `id` as default and clear `isDefault` on every
    /// other record. Throws if `id` doesn't exist. To clear the default
    /// without picking a new one, call `clearDefault()`.
    func setDefault(id: UUID) throws {
        guard var winner = organization(id: id) else {
            throw OrganizationStoreError.notFound(id)
        }
        winner.isDefault = true
        winner.updatedAt = Date()

        var updated = organizations.map { $0.id == id ? winner : $0 }
        updated = OrganizationValidation.enforceSingleDefault(after: winner, in: updated)
        organizations = sorted(updated)
        persist()
    }

    /// Clear the default flag on whichever org currently holds it.
    /// No-op if no org is marked default.
    func clearDefault() {
        guard let current = defaultOrg() else { return }
        var cleared = current
        cleared.isDefault = false
        cleared.updatedAt = Date()
        organizations = sorted(
            organizations.map { $0.id == current.id ? cleared : $0 }
        )
        persist()
    }

    // MARK: - Storage

    /// Default storage URL: `Application Support/<bundleName>/organizations.json`.
    /// Nonisolated so it works as an `init` default value.
    nonisolated static func defaultURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Jot"
        let dir = support.appendingPathComponent(appName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("organizations.json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Organization].self, from: data)
        else { return }
        organizations = sorted(decoded)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(organizations)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Log.pipeline.error(
                "OrganizationStore persist failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Default first, then alphabetical (case-insensitive). Consistent
    /// ordering keeps the sidebar list stable across reloads.
    private func sorted(_ list: [Organization]) -> [Organization] {
        list.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

/// Errors raised by store operations (separate from validation errors so
/// callers can pattern-match the cause).
enum OrganizationStoreError: Error, Equatable, LocalizedError {
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Organization \(id) not found."
        }
    }
}
