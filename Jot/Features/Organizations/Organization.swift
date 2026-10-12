import Foundation

/// One organization profile in the Context tab — a reusable bundle of names,
/// projects, glossary terms, and notes that get compiled into the Whisper
/// `prompt` payload at transcription time.
///
/// Persistence shape per PRD §5.1 + `Claude/implementation-plan.md` Phase A.1.
/// `schemaVersion` is set per `development-lifecycle.md` §6 so future field
/// changes can migrate forward without data loss.
struct Organization: Identifiable, Codable, Equatable, Sendable {

    let id: UUID
    var name: String
    var companyName: String?
    var staffNames: [String]
    var projectNames: [String]
    var glossaryTerms: [String]
    var acronyms: [AcronymEntry]

    /// Reference notes about the organization. **Not sent to Whisper** since
    /// v0.8: a prose sentence in the prompt was transcribed back as speech
    /// over every silence. Names and terms that need spelling guidance
    /// belong in the lists above.
    var freeformNotes: String?

    /// Default transcription language for this organization's meetings, as
    /// an ISO-639-1 code (`"nl"`), `TranscriptionLanguage.autoDetectCode`
    /// to force auto-detection, or `nil` to inherit the app-wide default.
    /// Overridable per meeting. Decodes as `nil` from files written before
    /// the field existed.
    var languageCode: String?

    var isDefault: Bool
    let createdAt: Date
    var updatedAt: Date

    /// On-disk schema version. Bumped when the persisted shape changes;
    /// readers dispatch on this in their custom `init(from:)`. Always 1
    /// for newly-created records.
    var schemaVersion: Int

    init(
        id: UUID = UUID(),
        name: String,
        companyName: String? = nil,
        staffNames: [String] = [],
        projectNames: [String] = [],
        glossaryTerms: [String] = [],
        acronyms: [AcronymEntry] = [],
        freeformNotes: String? = nil,
        languageCode: String? = nil,
        isDefault: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.name = name
        self.companyName = companyName
        self.staffNames = staffNames
        self.projectNames = projectNames
        self.glossaryTerms = glossaryTerms
        self.acronyms = acronyms
        self.freeformNotes = freeformNotes
        self.languageCode = languageCode
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}
