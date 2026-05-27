import Testing
import AppKit
@testable import Jot

/// Unit tests for `KeyCombo`. The type is small but it's the storage unit for
/// the hotkey across persistence (UserDefaults JSON) and the Phase 7 global
/// registrar, so equality, Codability, and display behavior are all contracts
/// worth pinning.
struct KeyComboTests {

    // MARK: - Construction & masking

    @Test
    func init_masksToDeviceIndependentFlags() {
        // Include the deprecated "function key" device-dependent flag — it
        // should be masked off so the stored raw value only contains
        // ⌘/⌥/⌃/⇧/caps/etc.
        let raw = NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.shift.rawValue
                | 0x10_0000 // arbitrary device-dependent bit
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        let combo = KeyCombo(keyCode: 15, modifierFlags: flags)
        let expected = NSEvent.ModifierFlags([.command, .shift])
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
        #expect(combo.modifierFlagsRaw == expected)
    }

    @Test
    func hasModifier_trueForCommandShift() {
        let combo = KeyCombo(keyCode: 15, modifierFlags: [.command, .shift])
        #expect(combo.hasModifier == true)
    }

    @Test
    func hasModifier_falseForBareKey() {
        let combo = KeyCombo(keyCode: 15, modifierFlags: [])
        #expect(combo.hasModifier == false)
    }

    // MARK: - Display string

    @Test
    func displayString_commandShiftR_isExpectedGlyphs() {
        let combo = KeyCombo(keyCode: 15, modifierFlags: [.command, .shift]) // 15 = R
        #expect(combo.displayString == "⇧⌘R")
    }

    @Test
    func displayString_modifierOrderIsControlOptionShiftCommand() {
        // Apple's convention orders modifiers ⌃⌥⇧⌘. Pin it.
        let combo = KeyCombo(
            keyCode: 0, // A
            modifierFlags: [.control, .option, .shift, .command]
        )
        #expect(combo.displayString == "⌃⌥⇧⌘A")
    }

    @Test
    func displayString_unknownKeyCode_fallsBackToKeyHash() {
        let combo = KeyCombo(keyCode: 200, modifierFlags: [.command])
        #expect(combo.displayString == "⌘Key #200")
    }

    // MARK: - Codable round-trip (used by AppSettings persistence)

    @Test
    func codable_roundTripPreservesValue() throws {
        let original = KeyCombo(keyCode: 15, modifierFlags: [.command, .shift])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func equatable_sameKeyDifferentModifiers_areNotEqual() {
        let a = KeyCombo(keyCode: 15, modifierFlags: [.command])
        let b = KeyCombo(keyCode: 15, modifierFlags: [.command, .shift])
        #expect(a != b)
    }

    @Test
    func equatable_differentKeyCodes_areNotEqual() {
        let a = KeyCombo(keyCode: 15, modifierFlags: [.command])
        let b = KeyCombo(keyCode: 16, modifierFlags: [.command])
        #expect(a != b)
    }
}
