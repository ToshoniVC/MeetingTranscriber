import Foundation

/// App-wide context that applies to *every* meeting, independent of the
/// selected organization. Three parts:
///
/// - `wrapperPrefix` — an optional lead-in prepended to the compiled Whisper
///   `prompt`. Empty by default since v0.8: any label-like lead-in is echo
///   bait during leading silence (an earlier default sentence was
///   transcribed back as speech). User-editable for anyone who wants one.
/// - `generalContext` — global free-text (terms, pronunciations, recurring
///   names) added to every transcription regardless of organization.
/// - `defaultLanguageCode` — the transcription language sent when neither
///   the meeting nor its organization pins one. Ships as Dutch (`nl`),
///   matching the user's meetings; empty or `TranscriptionLanguage.autoDetectCode`
///   means auto-detect.
///
/// Singleton on disk: there is exactly one record, owned by
/// `GeneralContextStore`. `schemaVersion` is carried per
/// `development-lifecycle.md` §6 so future field changes can migrate forward;
/// the decoder is tolerant of missing fields (defaults applied) so a
/// hand-edited or older file still loads.
struct GeneralContext: Codable, Equatable, Sendable {

    /// Shipped default for `defaultLanguageCode`.
    static let defaultLanguageCode = "nl"

    /// Lead-in prepended to the compiled prompt. Empty string = omit the
    /// lead-in entirely (the default).
    var wrapperPrefix: String

    /// Global free-text context applied to every meeting.
    var generalContext: String

    /// App-wide default transcription language (ISO-639-1), or empty /
    /// `TranscriptionLanguage.autoDetectCode` for auto-detect.
    var defaultLanguageCode: String

    /// Last edit time — surfaced nowhere yet, but kept for parity with the
    /// other persisted models and to let the UI detect external changes.
    var updatedAt: Date

    /// On-disk schema version. Always 1 for newly-created records.
    var schemaVersion: Int

    init(
        wrapperPrefix: String = ContextCompiler.defaultWrapperPrefix,
        generalContext: String = "",
        defaultLanguageCode: String = GeneralContext.defaultLanguageCode,
        updatedAt: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.wrapperPrefix = wrapperPrefix
        self.generalContext = generalContext
        self.defaultLanguageCode = defaultLanguageCode
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    // Tolerant decoder: any missing field falls back to its default rather
    // than failing the whole load. This keeps a partially-written or
    // older-schema file usable and makes adding fields later non-breaking.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.wrapperPrefix = try c.decodeIfPresent(String.self, forKey: .wrapperPrefix)
            ?? ContextCompiler.defaultWrapperPrefix
        self.generalContext = try c.decodeIfPresent(String.self, forKey: .generalContext) ?? ""
        self.defaultLanguageCode = try c.decodeIfPresent(String.self, forKey: .defaultLanguageCode)
            ?? GeneralContext.defaultLanguageCode
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}
