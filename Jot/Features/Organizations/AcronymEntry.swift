import Foundation

/// One acronym → expansion pair in an `Organization`'s glossary.
/// Rendered as `TERM = expansion` in the compiled context.
struct AcronymEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var term: String
    var expansion: String

    init(id: UUID = UUID(), term: String, expansion: String) {
        self.id = id
        self.term = term
        self.expansion = expansion
    }
}
