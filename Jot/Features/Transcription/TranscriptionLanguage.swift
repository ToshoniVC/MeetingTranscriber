import Foundation

/// Language pinning for the transcription request (`language` form field).
///
/// **Why.** Without a pinned language Whisper auto-detects per 30-second
/// window. On Jot's real recordings that produced fabricated Swedish and
/// Norwegian over silent openings and Dutch speech rendered in English. An
/// ISO-639-1 code tells the decoder which language to emit and removes
/// both failure modes.
///
/// **Resolution order.** Per-meeting choice → organization default → app-wide
/// default (`GeneralContext.defaultLanguageCode`) → auto-detect. Each level
/// stores either `nil` (inherit from the level below), `autoDetectCode`
/// (explicitly let the model decide), or an ISO code.
enum TranscriptionLanguage {

    /// Sentinel meaning "do not send a language; let the model detect it".
    /// Stored where a user deliberately overrides an inherited default with
    /// auto-detection. Never sent on the wire.
    static let autoDetectCode = "auto"

    /// Languages offered in the pickers. Deliberately short — Whisper
    /// accepts any ISO-639-1 code and `normalized(_:)` passes unknown codes
    /// through, so a power user can still type one into the General pane.
    static let pickerCodes: [String] = ["nl", "en", "fr", "de", "es", "it", "pt"]

    /// Human-readable name for a code via `Locale`, falling back to the raw
    /// code for anything the system can't name.
    static func displayName(for code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == autoDetectCode { return "Auto-detect" }
        let localized = Locale.current.localizedString(forLanguageCode: trimmed)
        guard let localized, !localized.isEmpty else { return trimmed }
        return localized.prefix(1).uppercased() + localized.dropFirst()
    }

    /// Trim + lowercase a stored code. Empty → `nil`. The sentinel survives
    /// so callers can tell "inherit" (`nil`) from "force auto-detect".
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Walk the levels (most specific first) and return the code to send,
    /// or `nil` for auto-detect. The first non-`nil` level wins; if that
    /// level is the auto-detect sentinel, nothing is sent.
    static func resolve(meeting: String?, organization: String?, general: String?) -> String? {
        for level in [meeting, organization, general] {
            guard let code = normalized(level) else { continue }
            return code == autoDetectCode ? nil : code
        }
        return nil
    }
}
