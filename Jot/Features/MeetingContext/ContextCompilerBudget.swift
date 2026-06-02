import Foundation

/// Character-budget knob for `ContextCompiler`. The Whisper `prompt` field
/// is hard-capped at 224 tokens server-side; 800 characters is ~200 tokens
/// for typical English with headroom for acronym-heavy content (which can
/// tokenize at ~1–2 chars/token — the exact case this feature exists to
/// support).
///
/// Tunable here so a provider with a different prompt window can be
/// accommodated without touching the compiler.
///
/// **Truncation strategy** (when the compiled string exceeds
/// `maxCharacters`): drop sections from the bottom of PRD §6 order
/// upward — meeting-specific context goes first, then meeting name,
/// then org freeform notes, then glossary/acronyms, then projects,
/// then staff, then the global general-context block (stickiest, since
/// the user set it to apply to every meeting). Organization identity
/// (name + company) and the wrapper prefix are *never* dropped.
struct ContextCompilerBudget: Equatable, Sendable {
    let maxCharacters: Int

    static let `default` = ContextCompilerBudget(maxCharacters: 800)
}
