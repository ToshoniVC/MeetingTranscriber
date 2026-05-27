import AppKit
import Foundation

/// A keyboard shortcut: a physical key plus modifier flags.
///
/// `KeyCombo` is a Codable value type so it can be persisted in `AppSettings`
/// via `UserDefaults` and round-tripped without losing fidelity.
///
/// Lives in `Core/Settings/` rather than `Features/Hotkey/` because
/// `AppSettings` (also in Core) needs to store it. Per coding-instructions §2,
/// Core can't depend on Features — so types shared by both live in Core.
///
/// `Features/Hotkey/HotkeyRegistrar.swift` (Phase 7) will translate this into
/// a global Carbon `RegisterEventHotKey` call. Phase 1 only stores/displays it.
struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    /// The virtual key code reported by `NSEvent.keyCode` for the captured key.
    let keyCode: UInt16

    /// `NSEvent.ModifierFlags.deviceIndependentFlagsMask`-masked raw value.
    /// Stored as `UInt` so it's plainly Codable.
    let modifierFlagsRaw: UInt

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        // Mask to device-independent flags so left/right variants and other
        // noise don't pollute equality. This matches what `NSEvent.charactersIgnoringModifiers`
        // and global hotkey APIs expect.
        let masked = modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.modifierFlagsRaw = masked.rawValue
    }

    /// Convenience accessor for the reconstructed flag set.
    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
    }

    /// Whether the combo contains at least one modifier. Global hotkeys without
    /// any modifier are almost always a bad idea (they intercept normal typing),
    /// so the UI uses this to gently warn but still allows it.
    var hasModifier: Bool {
        let interesting: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return !modifierFlags.intersection(interesting).isEmpty
    }

    /// Human-readable description like `⌘⇧R` or `⌥F12`, suitable for display
    /// in the Settings UI and the menu bar.
    var displayString: String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option)  { parts.append("⌥") }
        if modifierFlags.contains(.shift)   { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    /// Lookup table for the most common Mac virtual key codes → glyph used in
    /// `displayString`. Anything not in the table falls back to the raw
    /// "key #<code>" form so the user can at least *see* what they recorded
    /// even if we haven't mapped it.
    ///
    /// Source of truth for key codes: `<HIToolbox/Events.h>` (the same constants
    /// macOS has used since Carbon — they're stable).
    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 25: return "9"
        case 26: return "7"
        case 28: return "8"
        case 29: return "0"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 109: return "F10"
        case 111: return "F12"
        case 122: return "F1"
        case 120: return "F2"
        case 99...111, 118...120, 122...130:
            return "F\(keyCode)"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            return "Key #\(keyCode)"
        }
    }
}
