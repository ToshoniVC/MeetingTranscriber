import Foundation

/// One transcription provider configuration. Replaces the v0.4.4 single
/// `apiBaseURL` + `modelString` + `apiKey` triple in `AppSettings`. Users
/// can configure many simultaneously (OpenAI, Groq, a self-hosted Whisper,
/// …) and the pipeline walks the enabled ones in `sortOrder`, falling
/// through to the next when one fails.
///
/// **Why a separate per-provider record:** today the user can only have
/// one provider stored at a time. Switching from OpenAI to Groq means
/// pasting the Groq key over the OpenAI one, losing the OpenAI config.
/// Per the v0.4.5 PRD: multiple providers stored simultaneously, with
/// independent enable toggles and an ordered fallback chain.
///
/// **What's *not* in here:** the API key. Keys live in the Keychain
/// (file-backed per `Keychain.swift`) under
/// `account = "provider.<id.uuidString>"`. Storing keys here would put
/// them in plaintext alongside the JSON on disk; the existing Keychain
/// abstraction keeps them out.
///
/// Persistence: `Application Support/<bundleName>/providers.json`.
/// `schemaVersion` follows `Claude/development-lifecycle.md` §6 so
/// future field additions can migrate forward.
struct Provider: Identifiable, Codable, Equatable, Sendable {

    let id: UUID

    /// User-visible name shown in Settings, the audit log, and the
    /// Notion footer. Defaults to a name derived from `baseURL`'s host
    /// (e.g., `api.openai.com` → "OpenAI") on creation; users can rename.
    var displayName: String

    /// Fully-qualified endpoint URL (e.g.,
    /// `https://api.openai.com/v1/audio/transcriptions`). Stored as a
    /// string so a partial / in-progress URL the user is typing doesn't
    /// fail decoding. `ProviderValidation` decides whether it's complete
    /// enough to attempt a transcription.
    var baseURL: String

    /// Model identifier (e.g., `whisper-1`, `whisper-large-v3`). Sent
    /// verbatim in the multipart `model` field — providers pick which
    /// strings they accept.
    var model: String

    /// User toggle. Disabled providers stay in the list (so config isn't
    /// lost) but are skipped by the rotating transcriber. At least one
    /// enabled provider is required for the pipeline to start.
    var isEnabled: Bool

    /// Position in the fallback chain. Lower values come first. The
    /// rotating transcriber walks enabled providers in ascending
    /// `sortOrder` and tries each until one succeeds (user's v0.4.5
    /// directive: cascade on any error, including auth — see
    /// `RotatingTranscriber` for the safety note).
    var sortOrder: Int

    let createdAt: Date
    var updatedAt: Date

    /// On-disk schema version. Bumped when persisted shape changes.
    /// Always `1` for new records.
    var schemaVersion: Int

    init(
        id: UUID = UUID(),
        displayName: String,
        baseURL: String,
        model: String,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    // MARK: - Convenience

    /// Best-effort default displayName from a URL host. Used by the
    /// legacy-settings migration and by `+ Add provider` when the user
    /// hasn't typed a name yet. Returns `"Provider"` as a fallback so
    /// the UI always has something to render.
    static func suggestedDisplayName(forBaseURL urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
            return "Provider"
        }
        // Common providers: api.openai.com → OpenAI, api.groq.com → Groq,
        // api.anthropic.com → Anthropic, api.deepgram.com → Deepgram,
        // localhost / 127.0.0.1 → Local.
        if host.contains("openai") { return "OpenAI" }
        if host.contains("groq") { return "Groq" }
        if host.contains("anthropic") { return "Anthropic" }
        if host.contains("deepgram") { return "Deepgram" }
        if host == "localhost" || host.hasPrefix("127.") { return "Local" }
        // Otherwise capitalize the second-level domain: `api.foo.com` → "Foo".
        let parts = host.split(separator: ".")
        if parts.count >= 2 {
            let sld = parts[parts.count - 2]
            return sld.prefix(1).uppercased() + sld.dropFirst()
        }
        return "Provider"
    }

    /// Keychain account string under which this provider's API key is
    /// stored. Stable for the provider's lifetime; deletion is the
    /// store's job.
    var keychainAccount: String {
        "provider.\(id.uuidString)"
    }
}
