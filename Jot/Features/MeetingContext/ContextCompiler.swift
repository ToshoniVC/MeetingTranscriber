import Foundation

/// Pure compilation of `(Organization?, meetingSpecificContext, generalContext)`
/// into the Whisper prompt's **glossary**: one flat, comma-separated list of
/// the names and terms that need spelling guidance.
///
/// **Why a flat list.** The earlier labelled layout ("Organization: …",
/// "Staff: …", "Meeting: …", "Notes: …") was transcribed back over every
/// silent stretch — the organization and meeting lines most of all, and the
/// freeform notes sentence verbatim, dozens of times per meeting. Whisper's
/// `prompt` is spelling guidance, not instructions: labels and prose add
/// nothing it can use and give it sentences to regurgitate. So the compiler
/// now emits only the terms, drops the meeting name (file naming and Notion
/// still use it) and the freeform notes (kept on the organization for the
/// user's reference, never sent), and lets `TranscriptArtifactFilter` remove
/// whatever echo remains using this exact string as its reference.
///
/// Side-effect-free: the same inputs always produce the same string. That
/// determinism is what makes `context.md` useful as a reproducibility
/// artifact.
enum ContextCompiler {

    /// Default lead-in. Empty on purpose: a label-like prefix is itself echo
    /// bait during leading silence (an earlier default was transcribed back
    /// as speech). The live value is user-editable via `GeneralContext`
    /// (Context tab → General) for anyone who wants one.
    static let defaultWrapperPrefix = ""

    /// Compile the glossary. Returns `""` when there is nothing meaningful to
    /// send (no organization, no meeting-specific context, no general
    /// context) — callers interpret empty as "omit the `prompt` field".
    static func compile(
        meetingSpecificContext: String?,
        organization: Organization?,
        wrapperPrefix: String = defaultWrapperPrefix,
        generalContext: String? = nil,
        budget: ContextCompilerBudget = .default
    ) -> String {
        let trimmedMeetingContext = (meetingSpecificContext ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGeneral = (generalContext ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrefix = wrapperPrefix.trimmingCharacters(in: .whitespacesAndNewlines)

        if organization == nil && trimmedMeetingContext.isEmpty && trimmedGeneral.isEmpty {
            return ""
        }

        var sections: [Section] = []
        if !trimmedGeneral.isEmpty {
            sections.append(Section(kind: .generalContext, terms: [flattened(trimmedGeneral)]))
        }

        if let org = organization {
            let identity = identityTerms(org)
            if !identity.isEmpty {
                sections.append(Section(kind: .identity, terms: identity))
            }
            let staff = dedupe(org.staffNames)
            if !staff.isEmpty {
                sections.append(Section(kind: .staff, terms: staff))
            }
            let projects = dedupe(org.projectNames)
            if !projects.isEmpty {
                sections.append(Section(kind: .projects, terms: projects))
            }
            let glossary = glossaryTerms(terms: org.glossaryTerms, acronyms: org.acronyms)
            if !glossary.isEmpty {
                sections.append(Section(kind: .glossary, terms: glossary))
            }
        }

        if !trimmedMeetingContext.isEmpty {
            sections.append(Section(kind: .meetingContext, terms: [flattened(trimmedMeetingContext)]))
        }

        return render(sections, prefix: trimmedPrefix, budget: budget)
    }

    // MARK: - Section model + drop priority

    private struct Section {
        let kind: Kind
        let terms: [String]

        enum Kind {
            case generalContext
            case identity
            case staff
            case projects
            case glossary
            case meetingContext

            /// Higher = dropped first under budget pressure. `nil` = never
            /// dropped. General context is the stickiest *droppable* section —
            /// the user deliberately set it to apply to every meeting.
            var dropPriority: Int? {
                switch self {
                case .identity: return nil
                case .generalContext: return 1
                case .staff: return 2
                case .projects: return 3
                case .glossary: return 4
                case .meetingContext: return 5
                }
            }
        }
    }

    // MARK: - Term sources

    private static func identityTerms(_ org: Organization) -> [String] {
        let name = org.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let company = org.companyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var out: [String] = []
        if !name.isEmpty { out.append(name) }
        if !company.isEmpty, company.caseInsensitiveCompare(name) != .orderedSame {
            out.append(company)
        }
        return out
    }

    /// Glossary terms followed by acronyms rendered `TERM (Expansion)` — both
    /// spellings are useful guidance, and the parenthesis keeps the pair
    /// readable in `context.md` and the Notion "Additional Context" section.
    private static func glossaryTerms(terms: [String], acronyms: [AcronymEntry]) -> [String] {
        var out = dedupe(terms)
        for entry in dedupedAcronyms(acronyms) {
            out.append("\(entry.term) (\(entry.expansion))")
        }
        return out
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
            if seen.insert(trimmed.lowercased()).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    /// Same as `dedupe` but for acronyms; the dedupe key is the *term*, so
    /// two entries with the same term but different expansions collapse to
    /// the first.
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

    /// Free text (general / meeting-specific context) collapsed onto one
    /// line so the compiled glossary stays a single run of text.
    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Rendering + budget

    private static func render(
        _ sections: [Section],
        prefix: String,
        budget: ContextCompilerBudget
    ) -> String {
        func joined(_ keep: [Section]) -> String {
            // Dedupe across sections too — an organization name that also
            // appears in the glossary should not be listed twice.
            let terms = dedupe(keep.flatMap(\.terms))
            guard !terms.isEmpty else { return "" }
            let list = terms.joined(separator: ", ")
            return prefix.isEmpty ? list : prefix + " " + list
        }

        let full = joined(sections)
        if full.count <= budget.maxCharacters { return full }

        // Drop the least valuable sections first; deterministic tiebreak by
        // original index (later sections drop before earlier ones).
        let droppable = sections.indices
            .filter { sections[$0].kind.dropPriority != nil }
            .sorted { lhs, rhs in
                let lp = sections[lhs].kind.dropPriority ?? 0
                let rp = sections[rhs].kind.dropPriority ?? 0
                if lp != rp { return lp > rp }
                return lhs > rhs
            }
        var dropped = Set<Int>()
        for index in droppable {
            dropped.insert(index)
            let remaining = sections.indices.filter { !dropped.contains($0) }.map { sections[$0] }
            let candidate = joined(remaining)
            if candidate.count <= budget.maxCharacters { return candidate }
        }

        // Only the identity (and prefix) is left and it is still over budget.
        // Hard-truncate at a word boundary so we never blow the limit.
        let core = joined(sections.indices.filter { !dropped.contains($0) }.map { sections[$0] })
        return truncated(core, to: budget.maxCharacters)
    }

    private static func truncated(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let hard = String(text.prefix(maxCharacters))
        if let lastSpace = hard.lastIndex(of: " "), lastSpace > hard.startIndex {
            return String(hard[..<lastSpace]).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        }
        return hard
    }
}
