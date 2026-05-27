import SwiftUI
import AppKit

/// PRD §3.2 Tab 3 → "Recording Shortcut: a global hotkey recorder field."
///
/// Phase 1 only *records* and *stores* the `KeyCombo` in `AppSettings`. Phase 7
/// (`Features/Hotkey/HotkeyRegistrar.swift`) registers it globally via Carbon
/// and wires it to the Apple Shortcut that starts Audio Hijack.
struct HotkeySection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        SectionHeader(
            title: "Recording shortcut",
            systemImage: "keyboard",
            subtitle: "Press the shortcut anywhere to start recording. Global registration lands in Phase 7."
        )

        HStack(spacing: 12) {
            HotkeyRecorderField(
                keyCombo: settings.recordingHotkey,
                onChange: { settings.recordingHotkey = $0 }
            )
            .frame(maxWidth: 280)

            if settings.recordingHotkey != nil {
                Button("Clear", role: .destructive) {
                    settings.recordingHotkey = nil
                }
            }

            if let combo = settings.recordingHotkey, !combo.hasModifier {
                Label("Single keys without modifiers will intercept normal typing.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// The actual recorder. Clicking it enters "recording" mode where the next
/// keyDown becomes the new `KeyCombo`. Pressing Escape cancels.
private struct HotkeyRecorderField: View {
    let keyCombo: KeyCombo?
    let onChange: (KeyCombo?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            HStack {
                Image(systemName: isRecording ? "record.circle" : "command")
                    .foregroundStyle(isRecording ? .red : .secondary)
                Text(label)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? .red : Color.secondary.opacity(0.4),
                            lineWidth: isRecording ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, recording in
            if recording {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
        .onDisappear { stopMonitoring() }
    }

    private var label: String {
        if isRecording { return "Press any key combination…" }
        return keyCombo?.displayString ?? "Click to record"
    }

    /// Adds a local key-event monitor. "Local" means this app's events only —
    /// global registration is Phase 7's job.
    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels without changing the saved value.
            if event.keyCode == 53 { // kVK_Escape
                isRecording = false
                return nil
            }
            let combo = KeyCombo(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
            onChange(combo)
            isRecording = false
            return nil // consume the event
        }
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
