import Foundation
import Observation

/// Persistent store of `Provider` records — backs the Providers section
/// of the Settings tab and feeds the `RotatingTranscriber` its ordered
/// list of providers to try.
///
/// Mirrors `OrganizationStore`: `@MainActor` + `@Observable` so SwiftUI
/// binds directly; lazy load on init; persist atomically on every
/// mutation; per-bundle storage so Jot and Jot Dev have independent
/// provider sets.
///
/// **Storage location:** `Application Support/<bundleName>/providers.json`.
///
/// **API key handling.** The store does *not* persist API keys in the
/// JSON file — they go in the Keychain under
/// `account = "provider.<id.uuidString>"`. The store owns the lifecycle:
/// `setKey(_:for:)` writes through, `delete(id:)` removes both the
/// provider record AND its Keychain entry. The Keychain is injected so
/// tests can substitute an in-memory fake.
///
/// **Ordering invariant.** `providers` is always sorted by `sortOrder`
/// ascending, ties broken by `displayName` (case-insensitive). The
/// rotating transcriber relies on this order; UI drag-reorder updates
/// `sortOrder` for the affected rows.
@MainActor
@Observable
final class ProviderStore {

    /// Current snapshot, sorted by `sortOrder` then `displayName`.
    /// SwiftUI binds to this directly.
    private(set) var providers: [Provider] = []

    private let fileURL: URL
    private let keychain: KeychainStorage
    private var loaded = false

    init(
        fileURL: URL = ProviderStore.defaultURL(),
        keychain: KeychainStorage? = nil
    ) {
        self.fileURL = fileURL
        self.keychain = keychain ?? Keychain(
            service: Bundle.main.bundleIdentifier ?? "com.toshonivc.jot"
        )
        load()
    }

    // MARK: - Public API — providers

    /// Look up by id. `nil` if the provider has been deleted.
    func provider(id: UUID) -> Provider? {
        providers.first { $0.id == id }
    }

    /// Insert a new provider or update an existing one (matched by `id`).
    /// Validates via `ProviderValidation`. Re-stamps `updatedAt`. Trims
    /// the displayName + baseURL + model before persisting.
    @discardableResult
    func upsert(_ provider: Provider) throws -> Provider {
        try ProviderValidation.validate(provider, against: providers)

        var next = provider
        next.displayName = provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        next.baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        next.model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        next.updatedAt = Date()

        var updated = providers
        if let idx = updated.firstIndex(where: { $0.id == provider.id }) {
            updated[idx] = next
        } else {
            // New row goes at the bottom of the chain unless the caller
            // supplied a deliberate sortOrder. The deliberate-sortOrder
            // case (e.g., the legacy-settings migrator) keeps its choice.
            if next.sortOrder == 0 && !updated.isEmpty {
                next.sortOrder = (updated.map(\.sortOrder).max() ?? 0) + 1
            }
            updated.append(next)
        }
        providers = sorted(updated)
        persist()
        return next
    }

    /// Delete the provider with `id` and clear its API key from the
    /// Keychain. No-op if `id` doesn't exist.
    func delete(id: UUID) {
        guard let victim = provider(id: id) else { return }
        providers.removeAll { $0.id == id }
        try? keychain.deleteString(forKey: victim.keychainAccount)
        persist()
    }

    /// Replace the entire `sortOrder` mapping in one shot. Used by the
    /// list view's drag-to-reorder gesture: the caller passes the new
    /// id-ordered array and we rewrite `sortOrder` 0..<N to match.
    /// Idempotent — calling with the current order is a no-op.
    func reorder(toIDs orderedIDs: [UUID]) {
        var lookup = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        var changed = false
        for (index, id) in orderedIDs.enumerated() {
            guard var existing = lookup[id] else { continue }
            if existing.sortOrder != index {
                existing.sortOrder = index
                existing.updatedAt = Date()
                lookup[id] = existing
                changed = true
            }
        }
        guard changed else { return }
        providers = sorted(Array(lookup.values))
        persist()
    }

    /// The ordered list of providers the rotating transcriber should
    /// try. Disabled providers are excluded. Order matches the chain
    /// the user configured.
    func enabledOrdered() -> [Provider] {
        providers.filter(\.isEnabled).sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Public API — API keys

    /// Read this provider's API key from the Keychain, if one is set.
    func apiKey(for provider: Provider) -> String? {
        let value = keychain.getString(forKey: provider.keychainAccount)
        return (value?.isEmpty == false) ? value : nil
    }

    /// Whether the keychain currently holds a (non-empty) key for this
    /// provider. Convenience for the readiness helper in the UI.
    func hasAPIKey(for provider: Provider) -> Bool {
        apiKey(for: provider) != nil
    }

    /// Write or clear this provider's API key. Empty/nil clears.
    /// Tolerant of Keychain errors — secrets are logged-as-failed but
    /// the call doesn't throw, matching the pre-0.4.5 behavior on
    /// `AppSettings.apiKey`.
    func setAPIKey(_ value: String?, for provider: Provider) {
        do {
            if let value, !value.isEmpty {
                try keychain.setString(value, forKey: provider.keychainAccount)
            } else {
                try keychain.deleteString(forKey: provider.keychainAccount)
            }
        } catch {
            Log.pipeline.error(
                "ProviderStore set key failed for \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Decide the current readiness of every provider, in one shot.
    /// Useful for the Settings list rendering and for the pipeline-gate
    /// check in `PipelineCoordinator`.
    func readiness(of provider: Provider) -> ProviderReadiness {
        ProviderValidation.readiness(of: provider) { [weak self] candidate in
            self?.hasAPIKey(for: candidate) ?? false
        }
    }

    // MARK: - Storage

    /// Default storage URL: `Application Support/<bundleName>/providers.json`.
    /// Nonisolated so it can be a default `init` argument.
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
        return dir.appendingPathComponent("providers.json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Provider].self, from: data)
        else { return }
        providers = sorted(decoded)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(providers)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Log.pipeline.error(
                "ProviderStore persist failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sorted(_ list: [Provider]) -> [Provider] {
        list.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }
}
