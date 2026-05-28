import Foundation

/// Pure compilation of `(Organization?, meetingName, meetingSpecificContext)`
/// into the Whisper `prompt` string. Order per PRD §6; trim + dedupe within
/// each list; budget-truncate per `ContextCompilerBudget`.
///
/// Side-effect-free: callers (pipeline, snapshot store) get the same string
/// for the same inputs. That determinism is what makes `context.md`
/// (Phase G) useful as a reproducibility artifact.
enum ContextCompiler {

    /// One-liner that sets up Whisper to interpret the rest of the prompt
    /// as a glossary of names and terms.
    static let systemPrefix = "Transcription context. Names and terms used in this audio:"

    /// Compile per PRD §6. Returns `""` if there's nothing meaningful to
    /// send (no organization and no meeting-specific context) — callers
    /// interpret empty as "omit the `prompt` field entirely" (Phase F.4).
    static func compile(
        meetingName: String,
        meetingSpecificContext: String?,
        organization: Organization?,
        budget: ContextCompilerBudget = .default
    ) -> String {
        let trimmedMeetingContext = (meetingSpecificContext ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = meetingName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Per PRD §6: no org and no meeting-specific context → empty.
        // Meeting name alone is too weak a signal to bother including.
        if organization == nil && trimmedMeetingContext.isEmpty {
            return ""
        }

        var sections: [Section] = [Section(kind: .prefix, content: systemPrefix)]

        if let org = organization {
            let identity = renderIdentity(org)
            if !identity.isEmpty {
                sections.append(Section(kind: .orgIdentity, content: identity))
            }

            let staff = dedupe(org.staffNames)
            if !staff.isEmpty {
                sections.append(Section(kind: .staff, content: "Staff: " + staff.joined(separator: ", ")))
            }

            let projects = dedupe(org.projectNames)
            if !projects.isEmpty {
                sections.append(Section(kind: .projects, content: "Projects: " + projects.joined(separator: ", ")))
            }

            let glossary = renderGlossary(terms: org.glossaryTerms, acronyms: org.acronyms)
            if !glossary.isEmpty {
                sections.append(Section(kind: .glossary, content: glossary))
            }

            if let notes = org.freeformNotes?.trimmingCharacters(in: .whitespacesAndNewlines),
               !notes.isEmpty {
                sections.append(Section(kind: .orgNotes, content: "Notes: " + notes))
            }
        }

        if !trimmedName.isEmpty {
            sections.append(Section(kind: .meetingName, content: "Meeting: " + trimmedName))
        }

        if !trimmedMeetingContext.isEmpty {
            sections.append(Section(kind: .meetingContext, content: trimmedMeetingContext))
        }

        return joinWithBudget(sections, budget: budget)
    }

    // MARK: - Section model + drop priority

    private struct Section {
        let kind: Kind
        let content: String

        enum Kind {
            case prefix
            case orgIdentity
            case staff
            case projects
            case glossary
            case orgNotes
            case meetingName
            case meetingContext

            /// Higher = dropped first under budget pressure. `nil` = never
            /// dropped (prefix is tiny; org identity is the most valuable
            /// signal once the user named an org).
            var dropPriority: Int? {
                switch self {
                case .prefix: return nil
                case .orgIdentity: return nil
                case .staff: return 1
                case .projects: return 2
                case .glossary: return 3
                case .orgNotes: return 4
                case .meetingName: return 5
                case .meetingContext: return 6
                }
            }
        }
    }

    // MARK: - Section renderers

    private static func renderIdentity(_ org: Organization) -> String {
        let trimmedName = org.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCompany = org.companyName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !trimmedName.isEmpty, !trimmedCompany.isEmpty,
           trimmedName.caseInsensitiveCompare(trimmedCompany) != .orderedSame {
            return "Organization: \(trimmedName) (\(trimmedCompany))"
        }
        if !trimmedName.isEmpty {
            return "Organization: \(trimmedName)"
        }
        if !trimmedCompany.isEmpty {
            return "Organization: \(trimmedCompany)"
        }
        return ""
    }

    private static func renderGlossary(terms: [String], acronyms: [AcronymEntry]) -> String {
        let cleanTerms = dedupe(terms)
        let cleanAcronyms = dedupedAcronyms(acronyms)

        var parts: [String] = []
        if !cleanTerms.isEmpty {
            parts.append("Terms: " + cleanTerms.joined(separator: ", "))
        }
        if !cleanAcronyms.isEmpty {
            let rendered = cleanAcronyms
                .map { "\($0.term) = \($0.expansion)" }
                .joined(separator: "; ")
            parts.append("Acronyms: " + rendered)
        }
        return parts.joined(separator: ". ")
    }

    // MARK: - Trim + dedupe

    /// Trims, drops empties, and dedupes case-insensitively while preserving
    /// the first-seen order.
    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    /// Same as `dedupe` but for acronyms; the dedupe key is the *term*,
    /// so two entries with the same term but different expansions collapse
    /// to the first.
    private static func dedupedAcronyms(_ entries: [AcronymEntry]) -> [AcronymEntry] {
        var seen = Set<String>()
        var out: [AcronymEntry] = []
        for raw in entries {
            let term = raw.term.trimmingCharacters(in: .whitespacesAndNewlines)
            let expansion = raw.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !expansion.isEmpty else { continue }
            if seen.insert(term.lowercased()).inserted {
                out.append(AcronymEntry(id: raw.id, term: term, expansion: expansion))
            }
        }
        return out
    }

    // MARK: - Budget

    private static func joinWithBudget(
        _ sections: [Section],
        budget: ContextCompilerBudget
    ) -> String {
        let separator = "\n"
        func combined(_ keep: [Section]) -> String {
            keep.map(\.content).joined(separator: separator)
        }

        if combined(sections).count <= budget.maxCharacters {
            return combined(sections)
        }

        // Sort indices of droppable sections by drop priority (desc) so we
        // drop the least-valuable first. Stable across calls: deterministic
        // tiebreak by original index.
        let droppableIndices = sections.indices
            .filter { sections[$0].kind.dropPriority != nil }
            .sorted { lhs, rhs in
                let lp = sections[lhs].kind.dropPriority ?? 0
                let rp = sections[rhs].kind.dropPriority ?? 0
                if lp != rp { return lp > rp }
                return lhs > rhs
            }

        var dropped = Set<Int>()
        for i in droppableIndices {
            dropped.insert(i)
            let remaining = sections.enumerated()
                .filter { !dropped.contains($0.offset) }
                .map { $0.element }
            let joined = combined(remaining)
            if joined.count <= budget.maxCharacters {
                return joined
            }
        }

        // Even with everything droppable removed (prefix + org identity
        // only), still over. Last resort: hard-truncate the result so we
        // never blow the budget. In practice this only fires if the org
        // identity itself is enormous.
        let core = combined(sections.enumerated().filter { !dropped.contains($0.offset) }.map { $0.element })
        return String(core.prefix(budget.maxCharacters))
    }
}
