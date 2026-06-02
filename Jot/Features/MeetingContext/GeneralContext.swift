import Foundation

/// App-wide context that applies to *every* meeting, independent of the
/// selected organization. Two parts:
///
/// - `wrapperPrefix` — the lead-in line prepended to the compiled Whisper
///   `prompt`. Moved out of code (it used to be a baked constant in
///   `ContextCompiler`) so the user can tune it without a rebuild — the
///   default sentence form turned out to be echo-prone during leading
///   silence (Whisper would transcribe the prompt back as if spoken).
/// - `generalContext` — global free-text (terms, pronunciations, recurring
///   names) added to every transcription regardless of organization.
///
/// Singleton on disk: there is exactly one record, owned by
/// `GeneralContextStore`. `schemaVersion` is carried per
/// `development-lifecycle.md` §6 so future field changes can migrate forward;
/// the decoder is tolerant of missing fields (defaults applied) so a
/// hand-edited or older file still loads.
struct GeneralContext: Codable, Equatable, Sendable {

    /// Lead-in prepended to the compiled prompt. Empty string = omit the
    /// lead-in entirely (a deliberate, supported choice).
    var wrapperPrefix: String

    /// Global free-text context applied to every meeting.
    var generalContext: String

    /// Last edit time — surfaced nowhere yet, but kept for parity with the
    /// other persisted models and to let the UI detect external changes.
    var updatedAt: Date

    /// On-disk schema version. Always 1 for newly-created records.
    var schemaVersion: Int

    init(
        wrapperPrefix: String = ContextCompiler.defaultWrapperPrefix,
        generalContext: String = "",
        updatedAt: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.wrapperPrefix = wrapperPrefix
        self.generalContext = generalContext
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
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}
