import Foundation

/// Character-budget knob for `ContextCompiler`. The Whisper `prompt` field
/// is hard-capped at 224 tokens server-side and the compiled glossary
/// shares that window with the previous part's continuation tail
/// (`TranscriptionPrompt.continuationBudget`, 400 chars). 300 characters is
/// roughly 100 tokens for Dutch, which tokenizes at about three characters
/// per token — acronym-heavy lists are worse, so there is headroom.
///
/// Smaller is also better on its own merits: every term in the prompt is a
/// term Whisper can echo over silence, so the list should hold only the
/// names and jargon that actually need spelling guidance.
///
/// **Truncation strategy** (when the compiled string exceeds
/// `maxCharacters`): drop whole sections, least valuable first — the
/// meeting-specific context, then glossary/acronyms, then projects, then
/// staff, then the app-wide general context (stickiest, since the user set
/// it to apply to every meeting). Organization name and company are never
/// dropped.
struct ContextCompilerBudget: Equatable, Sendable {
    let maxCharacters: Int

    static let `default` = ContextCompilerBudget(maxCharacters: 300)
}
