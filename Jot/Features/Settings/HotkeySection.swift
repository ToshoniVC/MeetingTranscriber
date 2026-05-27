import SwiftUI
import AppKit

/// PRD §3.2 Tab 3 → Recording shortcut, with PRD §5's "ask for meeting
/// name + start Audio Hijack" out-of-the-box flow now built in.
///
/// By default Jot runs its embedded Audio Hijack flow when the hotkey
/// fires. Power users (non-AH workflows: Loopback / OBS / Audacity / …)
/// can flip the picker and supply their own Apple Shortcut instead.
struct HotkeySection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HotkeyCoordinator.self) private var hotkey

    @State private var testFeedback: TestFeedback?

    var body: some View {
        @Bindable var bindable = settings

        SectionHeader(
            title: "Recording shortcut",
            systemImage: "keyboard",
            subtitle: "Press the shortcut anywhere to start recording."
        )

        VStack(alignment: .leading, spacing: 16) {
            // Prerequisite banner — Audio Hijack is required for the
            // built-in flow.
            AudioHijackBlock()

            LabeledField(label: "Hotkey") {
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
                }
            }

            // Inline registration error — usually "another app already has
            // this combo" or "grant Accessibility permission".
            if let error = hotkey.registrationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            } else if let combo = settings.recordingHotkey, !combo.hasModifier {
                Label("Single keys without modifiers will intercept normal typing.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            // Inline trigger error — last failed hotkey press. The most
            // common cause is "Automation permission for Jot → Audio Hijack
            // is not granted" — the user can't see the audit log from here,
            // so we put the same message inline.
            if let triggerError = hotkey.lastTriggerError {
                Label(triggerError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Mode picker — built-in toggle (default) vs single-Shortcut override.
            LabeledField(label: "On press") {
                Picker("", selection: $bindable.useBuiltInRecording) {
                    Text("Toggle Audio Hijack (asks for meeting name)").tag(true)
                    Text("Run a single Apple Shortcut").tag(false)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
            }

            if settings.useBuiltInRecording {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledField(label: "Start Shortcut") {
                        TextField("Jot Start Recording", text: $bindable.startShortcutName)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .frame(maxWidth: 360)
                    }
                    ShortcutHowToCard(
                        kind: .start,
                        shortcutName: settings.startShortcutName
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    LabeledField(label: "Stop Shortcut") {
                        TextField("Jot Stop Recording", text: $bindable.stopShortcutName)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .frame(maxWidth: 360)
                    }
                    ShortcutHowToCard(
                        kind: .stop,
                        shortcutName: settings.stopShortcutName
                    )
                }

                Text("Audio Hijack 4 has no AppleScript, so Jot drives it via two Shortcuts you author once. The Start Shortcut runs Audio Hijack's **Run/Stop Session** action with State = Running; the Stop Shortcut uses State = Stopped. Jot tracks whether it's recording locally and picks the right one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LabeledField(label: "Shortcut name") {
                    TextField("Jot Toggle Recording", text: $bindable.customShortcutName)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .frame(maxWidth: 360)
                }
                Text("The named Apple Shortcut runs on every hotkey press — no prompt, no recording-state tracking. Use this if you want the Shortcut itself to decide whether to start or stop, or for non-Audio-Hijack workflows (Loopback, OBS, Audacity, …).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Test recording") {
                    Task { await runTest() }
                }
                .disabled(!testEnabled)

                if let feedback = testFeedback {
                    Label(feedback.text, systemImage: feedback.systemImage)
                        .font(.callout)
                        .foregroundStyle(feedback.color)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var testEnabled: Bool {
        if settings.useBuiltInRecording {
            let start = settings.startShortcutName.trimmingCharacters(in: .whitespaces)
            let stop = settings.stopShortcutName.trimmingCharacters(in: .whitespaces)
            return !start.isEmpty && !stop.isEmpty
        } else {
            return !settings.customShortcutName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func runTest() async {
        testFeedback = nil
        let error = await hotkey.testRecordingNow()
        if let error {
            testFeedback = .failure(error)
        } else {
            testFeedback = .success("Recording started.")
        }
    }

    private enum TestFeedback {
        case success(String)
        case failure(String)

        var text: String {
            switch self {
            case .success(let m), .failure(let m): return m
            }
        }
        var color: Color {
            switch self {
            case .success: return .green
            case .failure: return .red
            }
        }
        var systemImage: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            }
        }
    }
}

/// The actual recorder field. Clicking it enters "recording" mode where the
/// next keyDown becomes the new `KeyCombo`. Pressing Escape cancels.
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

    /// Adds a local key-event monitor. "Local" means this app's events only.
    /// Global registration is handled by `HotkeyRegistrar` once a combo is
    /// saved into `AppSettings.recordingHotkey`.
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

/// Collapsible "How to create this Shortcut" walkthrough. Sits directly
/// below each Shortcut name field in `HotkeySection`. The shortcut name in
/// the rename step interpolates the current setting, so the instructions
/// stay accurate if the user renames the Shortcut.
private struct ShortcutHowToCard: View {

    enum Kind {
        case start
        case stop

        /// The AH4 "State" parameter the user should pick.
        var stateValue: String {
            switch self {
            case .start: return "Running"
            case .stop:  return "Stopped"
            }
        }

        var disclosureLabel: String {
            switch self {
            case .start: return "How to create the Start Shortcut"
            case .stop:  return "How to create the Stop Shortcut"
            }
        }
    }

    let kind: Kind
    let shortcutName: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        // .init(...) parses the string as Markdown so **bold**
                        // and `code` render without us hand-rolling AttributedString.
                        Text(.init(step))
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        openShortcutsApp()
                    } label: {
                        Label("Open Shortcuts app", systemImage: "command")
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06))
            }
            .padding(.top, 4)
        } label: {
            Label(kind.disclosureLabel, systemImage: "questionmark.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// The step-by-step instructions, rendered as Markdown. The Stop card
    /// is shorter because steps that are identical to Start can be replaced
    /// with "same as the Start Shortcut" prompts.
    private var steps: [String] {
        switch kind {
        case .start:
            return [
                "Make sure **Audio Hijack is running** — Shortcuts only surfaces an app's actions after the app has been launched at least once this session.",
                "Open the **Shortcuts** app on your Mac (the button below opens it).",
                "Click the **+** button at the top of the Shortcuts window to create a new Shortcut.",
                "In the right-hand actions panel, search for **Run/Stop Session** (with the slash — it's the exact action name). If nothing shows up, search for **Audio Hijack** instead to browse all of AH's contributed actions.",
                "Drag **Run/Stop Session** into the empty workflow area on the left.",
                "Inside the action, click the **Session** dropdown and pick the Audio Hijack session you set up for recording.",
                "Click the **State** dropdown and set it to **\(kind.stateValue)**. After both are set, the action's title in the editor reads **\"Set the session X to \(kind.stateValue)\"** — that's expected.",
                "At the very top of the editor, click the Shortcut name (it starts as \"New Shortcut\") and rename it to exactly `\(shortcutName)` — case and spacing must match what's in the field above.",
                "Close the Shortcut editor window. Shortcuts autosaves — no Save button needed.",
                "**Optional:** drag a **Get Shortcut Input** action above **Run/Stop Session** if you want to use the meeting name Jot pipes in. The input arrives as plain text — feed it into a Notification action, save it to a variable, or use it however you like."
            ]
        case .stop:
            return [
                "Make sure **Audio Hijack is running** so the **Run/Stop Session** action surfaces in the Shortcuts actions panel.",
                "Open the **Shortcuts** app (button below).",
                "Click the **+** button to create a new Shortcut.",
                "Search the actions panel for **Run/Stop Session** (with the slash) and drag it into the workflow area. If you can't find it, search **Audio Hijack** to browse the app's actions directly.",
                "Click the **Session** dropdown and pick the **same** Audio Hijack session you used for the Start Shortcut.",
                "Click the **State** dropdown and set it to **\(kind.stateValue)**.",
                "Rename the Shortcut at the top of the editor to exactly `\(shortcutName)` — match the field above.",
                "Close the Shortcut editor — it autosaves."
            ]
        }
    }

    private func openShortcutsApp() {
        if let url = URL(string: "shortcuts://") {
            NSWorkspace.shared.open(url)
        }
    }
}
