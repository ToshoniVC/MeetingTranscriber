import Foundation

/// Validation rules for `Provider` records. Kept separate from the model
/// + store so the rules are unit-testable in isolation and the store
/// stays focused on persistence + ordering.
enum ProviderValidationError: Error, Equatable, LocalizedError {
    case displayNameEmpty
    case displayNameDuplicate(String)
    case baseURLEmpty
    case baseURLInvalid(String)
    case modelEmpty

    var errorDescription: String? {
        switch self {
        case .displayNameEmpty:
            return "Provider name can't be empty."
        case .displayNameDuplicate(let name):
            return "A provider named \"\(name)\" already exists."
        case .baseURLEmpty:
            return "Base URL is required."
        case .baseURLInvalid(let raw):
            return "Base URL is invalid (\(raw))."
        case .modelEmpty:
            return "Model identifier is required (e.g. `whisper-1`)."
        }
    }
}

/// Whether a provider is ready to be invoked. Mirrors
/// `NotionValidation.Outcome` — the Settings UI uses this to enable or
/// disable a per-row test button.
enum ProviderReadiness: Equatable {
    /// Has a valid baseURL, model, AND an API key in the keychain.
    case ready

    /// Configuration is complete but the API key entry is missing.
    /// Most common right after creating a provider before pasting the key.
    case missingKey

    /// One of baseURL / model is empty or malformed.
    case incomplete

    /// User has flipped the per-provider toggle off. Pipeline skips it
    /// without trying — separate state from `incomplete` because the
    /// config could be perfectly fine, just temporarily silenced.
    case disabled
}

enum ProviderValidation {

    /// Validate the editable fields on a `Provider` before persisting.
    /// `existing` is the current store snapshot used to detect
    /// duplicate display names (case-insensitive). Pass an empty array
    /// when creating the very first provider.
    static func validate(_ provider: Provider, against existing: [Provider]) throws {
        let name = provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            throw ProviderValidationError.displayNameEmpty
        }
        if existing.contains(where: {
            $0.id != provider.id
            && $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            throw ProviderValidationError.displayNameDuplicate(name)
        }

        let urlString = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlString.isEmpty {
            throw ProviderValidationError.baseURLEmpty
        }
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw ProviderValidationError.baseURLInvalid(urlString)
        }

        if provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProviderValidationError.modelEmpty
        }
    }

    /// Decide a provider's readiness given the current key state.
    /// `hasKey` is a closure so callers can plug in their own Keychain
    /// access without us reaching out for it. Pure function — no I/O.
    static func readiness(of provider: Provider, hasKey: (Provider) -> Bool) -> ProviderReadiness {
        if !provider.isEnabled { return .disabled }
        do {
            try validate(provider, against: [])  // empty: don't fail on name uniqueness here
        } catch {
            return .incomplete
        }
        return hasKey(provider) ? .ready : .missingKey
    }
}
