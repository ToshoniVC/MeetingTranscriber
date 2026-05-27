import AppKit
import Carbon.HIToolbox
import Foundation

/// Errors `HotkeyRegistrar` can surface to the UI.
enum HotkeyError: Error, Equatable {
    /// Carbon's `RegisterEventHotKey` returned a non-`noErr` status. The
    /// most common cause is "another app already grabbed this combo".
    case registrationFailed(osStatus: OSStatus)
}

/// Protocol implemented by `HotkeyRegistrar` so tests can substitute a fake
/// that doesn't actually install a global Carbon handler.
@MainActor
protocol HotkeyRegistering: AnyObject {
    /// Replace any existing registration with `combo`. The given closure is
    /// invoked on `MainActor` each time the hotkey fires.
    func register(_ combo: KeyCombo, onTrigger: @escaping @MainActor () -> Void) throws

    /// Unregister and stop receiving callbacks. Idempotent.
    func unregister()
}

/// Production implementation backed by Carbon's `RegisterEventHotKey`.
///
/// Carbon is the only modern macOS API for app-global, system-wide hotkeys
/// that aren't tied to a focused window. The bridging here is intentionally
/// confined — the rest of the app talks to `HotkeyRegistering`, not Carbon
/// directly.
///
/// Threading: all calls happen on `@MainActor`. Carbon's `EventDispatcher`
/// runs the event handler on the main run loop, so the trigger callback is
/// already main-safe.
@MainActor
final class HotkeyRegistrar: HotkeyRegistering {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Storage for the active trigger closure. Class-level (`static`)
    /// because Carbon's C event handler can't capture a Swift instance
    /// without unsafe pointer juggling — and Jot only ever has one global
    /// hotkey at a time, so a static holder is enough.
    nonisolated(unsafe) private static var activeTrigger: (@MainActor () -> Void)?

    init() {
        installEventHandlerOnce()
    }

    deinit {
        // NB: deinit can't be @MainActor. Carbon's unregister is
        // thread-safe; the ref is plain C state, so calling it here is fine.
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    // MARK: - HotkeyRegistering

    func register(_ combo: KeyCombo, onTrigger: @escaping @MainActor () -> Void) throws {
        unregister()
        Self.activeTrigger = onTrigger

        let id = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            carbonModifiers(from: combo.modifierFlags),
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let registered = ref else {
            Self.activeTrigger = nil
            throw HotkeyError.registrationFailed(osStatus: status)
        }
        hotKeyRef = registered
        Log.app.info("Registered global hotkey: \(combo.displayString, privacy: .public)")
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        Self.activeTrigger = nil
    }

    // MARK: - Carbon bridging

    /// `'JOTH'` as an `OSType` (FourCharCode) — a stable identifier that
    /// distinguishes our hotkey from anything else registered system-wide.
    private static let hotKeySignature: OSType = 0x4A4F5448

    /// Translate Cocoa modifier flags to Carbon's modifier bitfield.
    private func carbonModifiers(from cocoa: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if cocoa.contains(.command) { carbon |= UInt32(cmdKey) }
        if cocoa.contains(.option)  { carbon |= UInt32(optionKey) }
        if cocoa.contains(.control) { carbon |= UInt32(controlKey) }
        if cocoa.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Install the single C event handler that fans every hotkey press out
    /// to whatever `activeTrigger` is currently set. Safe to call multiple
    /// times — only installs once per instance.
    private func installEventHandlerOnce() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ -> OSStatus in
                // Hop to the main actor to invoke the trigger.
                if let trigger = HotkeyRegistrar.activeTrigger {
                    Task { @MainActor in
                        trigger()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handler
        )
        if status == noErr {
            eventHandlerRef = handler
        } else {
            Log.app.error("InstallEventHandler failed: \(status)")
        }
    }
}
