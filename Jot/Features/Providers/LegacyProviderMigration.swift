import Foundation

/// One-way migration from the v0.4.4 single-provider settings
/// (`AppSettings.apiBaseURL` / `modelString` / `apiKey`) to the v0.4.5
/// `ProviderStore`. Runs at app launch right after both stores exist
/// but before the pipeline starts, so the migration's output is what
/// the pipeline picks up.
///
/// **Idempotent.** Once a `ProviderStore` has any entries, the
/// migration is a no-op — we never overwrite a user-curated chain with
/// the legacy single entry. Multiple runs across launches are
/// equivalent to one.
///
/// **What we DON'T do.** We don't clear the legacy `AppSettings.apiKey`
/// (Keychain entry under `api_key`). Defensively kept around so if the
/// migration produced something the user doesn't expect, the original
/// secret is still recoverable. Future cleanup may delete it once
/// telemetry shows the migration is reliable.
enum LegacyProviderMigration {

    /// Result of one migration pass — surfaced to callers so they can
    /// log + react. Not strictly required for correctness; mostly for
    /// observability + tests.
    enum Outcome: Equatable {
        /// `ProviderStore` already had at least one entry — nothing to do.
        case alreadyMigrated

        /// No legacy data worth migrating (any of baseURL/model/apiKey
        /// missing or empty). Common on fresh installs.
        case noLegacyData

        /// A new `Provider` was created from the legacy fields.
        case migrated(Provider)
    }

    /// Inspect `settings` and `store`. If the store is empty and the
    /// legacy single-provider fields are populated, materialize a
    /// `Provider` from them with `sortOrder = 0` and `isEnabled = true`,
    /// write its key to the per-provider Keychain account, and return
    /// `.migrated(...)`.
    @discardableResult
    @MainActor
    static func migrateIfNeeded(
        settings: AppSettings,
        store: ProviderStore
    ) -> Outcome {
        guard store.providers.isEmpty else {
            return .alreadyMigrated
        }

        let baseURL = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.modelString.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (settings.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURL.isEmpty, !model.isEmpty, !apiKey.isEmpty else {
            return .noLegacyData
        }

        let displayName = Provider.suggestedDisplayName(forBaseURL: baseURL)
        let provider = Provider(
            displayName: displayName,
            baseURL: baseURL,
            model: model,
            isEnabled: true,
            sortOrder: 0
        )

        do {
            let saved = try store.upsert(provider)
            store.setAPIKey(apiKey, for: saved)
            Log.pipeline.info(
                "Migrated legacy single-provider settings → \(displayName, privacy: .public) (\(saved.id.uuidString, privacy: .public))"
            )
            return .migrated(saved)
        } catch {
            Log.pipeline.error(
                "Legacy migration failed: \(error.localizedDescription, privacy: .public)"
            )
            return .noLegacyData
        }
    }
}
