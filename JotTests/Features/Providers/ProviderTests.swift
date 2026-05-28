import Testing
import Foundation
@testable import Jot

/// Unit tests for `Provider` — pure-value behaviour: codable round-trip,
/// keychain account derivation, displayName suggester.
struct ProviderTests {

    @Test
    func init_defaultsAreSensible() {
        let p = Provider(displayName: "OpenAI", baseURL: "https://api.openai.com/v1/audio/transcriptions", model: "whisper-1")
        #expect(p.isEnabled)
        #expect(p.sortOrder == 0)
        #expect(p.schemaVersion == 1)
    }

    @Test
    func codable_roundTrips() throws {
        let original = Provider(
            id: UUID(),
            displayName: "Groq",
            baseURL: "https://api.groq.com/openai/v1/audio/transcriptions",
            model: "whisper-large-v3",
            isEnabled: false,
            sortOrder: 2
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Provider.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func keychainAccount_isStableForId() {
        let id = UUID()
        let p = Provider(id: id, displayName: "X", baseURL: "https://x/", model: "m")
        #expect(p.keychainAccount == "provider.\(id.uuidString)")
    }

    // MARK: - suggestedDisplayName

    @Test
    func suggestedDisplayName_picksOpenAI() {
        #expect(Provider.suggestedDisplayName(forBaseURL: "https://api.openai.com/v1/audio/transcriptions") == "OpenAI")
    }

    @Test
    func suggestedDisplayName_picksGroq() {
        #expect(Provider.suggestedDisplayName(forBaseURL: "https://api.groq.com/openai/v1/audio/transcriptions") == "Groq")
    }

    @Test
    func suggestedDisplayName_picksAnthropic() {
        #expect(Provider.suggestedDisplayName(forBaseURL: "https://api.anthropic.com/v1/foo") == "Anthropic")
    }

    @Test
    func suggestedDisplayName_picksLocalForLocalhost() {
        #expect(Provider.suggestedDisplayName(forBaseURL: "http://localhost:8080/v1/transcribe") == "Local")
        #expect(Provider.suggestedDisplayName(forBaseURL: "http://127.0.0.1:9000/v1") == "Local")
    }

    @Test
    func suggestedDisplayName_fallsBackToSLDCapitalized() {
        // api.mystery.com → "Mystery"
        #expect(Provider.suggestedDisplayName(forBaseURL: "https://api.mystery.com/v1/audio") == "Mystery")
    }

    @Test
    func suggestedDisplayName_unparseableURL_returnsProvider() {
        #expect(Provider.suggestedDisplayName(forBaseURL: "not a url at all") == "Provider")
        #expect(Provider.suggestedDisplayName(forBaseURL: "") == "Provider")
    }
}
