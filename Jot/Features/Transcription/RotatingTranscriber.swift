import Foundation

/// Walks an ordered list of providers, calling `TranscriptionClient` for
/// each until one succeeds. Replaces the single-provider transcribe
/// call ProcessingPipeline used through v0.4.4.
///
/// **Fallback policy (v0.4.5).** Per the PRD answer the user picked:
/// **any** failure falls through to the next enabled provider — network,
/// 5xx, 4xx (including auth), malformed response, all of it. This is
/// the most aggressive fallback option. The trade-off is honest: a
/// wrong API key on provider 1 silently bills provider 2 every meeting.
/// We surface that risk in Settings UI copy + the audit log so it's
/// visible.
///
/// **Why a wrapper struct, not a method on `TranscriptionClient`:**
/// keeps the existing `TranscriptionClient` single-provider focused
/// (testing each provider in isolation stays simple), and lets the
/// rotation logic be unit-tested by injecting a `Transcribing` fake
/// without dragging URLProtocol mocks along.
///
/// **Provider attribution.** The returned `TranscriptionResult.providerName`
/// is set to the displayName of the provider that *succeeded*. Callers
/// (ProcessingPipeline) thread it through to the audit log and the
/// Notion footer per the v0.4.5 attribution decision.
struct RotatingTranscriber: Sendable {

    /// What `RotatingTranscriber` needs from the per-provider client.
    /// `TranscriptionClient` conforms via an extension below; tests
    /// inject a fake to drive specific success/fail sequences without
    /// stubbing URLProtocol per attempt.
    protocol Transcribing: Sendable {
        func transcribe(
            audio: URL,
            baseURL: URL,
            model: String,
            apiKey: String,
            prompt: String?
        ) async throws -> TranscriptionResult
    }

    /// What `RotatingTranscriber` needs from the store. The full
    /// `ProviderStore` API is overkill here — we just need the ordered
    /// enabled chain plus per-provider key access. A protocol so tests
    /// don't need to stand up a Keychain + file store.
    protocol Source: Sendable {
        @MainActor func enabledOrdered() -> [Provider]
        @MainActor func apiKey(for provider: Provider) -> String?
    }

    /// Errors specific to the rotation layer, raised when no usable
    /// provider exists or the entire chain failed.
    enum RotationError: Error, Equatable, LocalizedError {
        /// No providers are enabled — pipeline gate should prevent us
        /// from reaching here, but defensively handled.
        case noEnabledProviders

        /// Every enabled provider was tried and every one failed. The
        /// associated value is the user-visible message from the LAST
        /// attempt — the most recently seen error is the one we
        /// surface, on the theory that "the final fallback also failed"
        /// is the most actionable summary.
        case allProvidersFailed(lastMessage: String, attempts: Int)

        var errorDescription: String? {
            switch self {
            case .noEnabledProviders:
                return "No transcription providers are enabled in Settings."
            case .allProvidersFailed(let message, let attempts):
                return "All \(attempts) transcription provider(s) failed. Last error: \(message)"
            }
        }
    }

    private let client: Transcribing
    private let source: Source

    init(client: Transcribing, source: Source) {
        self.client = client
        self.source = source
    }

    /// Walk the enabled-and-ordered providers and return the first
    /// successful `TranscriptionResult` — with its `providerName` set
    /// to the provider that delivered it.
    ///
    /// A provider is **skipped** (not counted as a failed attempt) when
    /// its API key is missing — that's a configuration omission, not a
    /// runtime failure. A provider whose key is present but invalid IS
    /// counted as a failed attempt and the chain falls through, per the
    /// v0.4.5 all-error fallback policy.
    func transcribe(
        audio: URL,
        prompt: String? = nil
    ) async throws -> TranscriptionResult {
        let providers = await source.enabledOrdered()
        guard !providers.isEmpty else {
            throw RotationError.noEnabledProviders
        }

        var attempts = 0
        var lastError: Error?
        for provider in providers {
            guard let apiKey = await source.apiKey(for: provider), !apiKey.isEmpty else {
                Log.transcription.warning(
                    "Skipping provider \(provider.displayName, privacy: .public) — no API key set."
                )
                continue
            }
            guard let baseURL = URL(string: provider.baseURL), baseURL.scheme != nil else {
                Log.transcription.warning(
                    "Skipping provider \(provider.displayName, privacy: .public) — invalid base URL: \(provider.baseURL, privacy: .public)"
                )
                continue
            }

            attempts += 1
            Log.transcription.info(
                "Attempting transcription via \(provider.displayName, privacy: .public) (attempt \(attempts, privacy: .public))"
            )

            do {
                var result = try await client.transcribe(
                    audio: audio,
                    baseURL: baseURL,
                    model: provider.model,
                    apiKey: apiKey,
                    prompt: prompt
                )
                result.providerName = provider.displayName
                Log.transcription.info(
                    "Transcription succeeded via \(provider.displayName, privacy: .public)"
                )
                return result
            } catch {
                lastError = error
                let message = (error as? TranscriptionError)?.userFacingMessage
                    ?? error.localizedDescription
                Log.transcription.warning(
                    "Provider \(provider.displayName, privacy: .public) failed: \(message, privacy: .public). Falling through to next."
                )
            }
        }

        if attempts == 0 {
            throw RotationError.noEnabledProviders
        }
        let message = (lastError as? TranscriptionError)?.userFacingMessage
            ?? lastError?.localizedDescription
            ?? "Unknown error"
        throw RotationError.allProvidersFailed(lastMessage: message, attempts: attempts)
    }
}

// MARK: - Adapters

/// `TranscriptionClient` is already shaped exactly like `Transcribing`;
/// the conformance is a trivial bridge. Kept in this file so the link
/// between client and rotator is obvious to anyone reading either.
extension TranscriptionClient: RotatingTranscriber.Transcribing {}

/// `ProviderStore` adopts `Source` so production callers can pass the
/// store directly without an adapter. Tests substitute their own fake
/// for tighter control over the chain.
extension ProviderStore: RotatingTranscriber.Source {}
