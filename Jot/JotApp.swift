import SwiftUI
import AppKit

/// The Jot app entry point.
///
/// Owns the long-lived `@MainActor` objects that the rest of the app reads
/// from the environment: `AppSettings`, `AuditLogStore`, `MenuBarController`,
/// and the `PipelineCoordinator` that wires them together with the
/// `FolderWatcher` + `TranscriptionClient` + `FileOrganizer`.
@main
struct JotApp: App {
    @State private var menuBar: MenuBarController
    @State private var settings: AppSettings
    @State private var auditLog: AuditLogStore
    @State private var pipeline: PipelineCoordinator
    @State private var hotkey: HotkeyCoordinator
    @State private var loginItem: LoginItemController
    @State private var audioHijack: AudioHijackPresence
    @State private var audioHijackController: AudioHijackController

    init() {
        let menuBar = MenuBarController()
        let settings = AppSettings()
        let auditLog = AuditLogStore()
        let pipeline = PipelineCoordinator(
            settings: settings,
            auditLog: auditLog,
            menuBar: menuBar
        )
        let audioHijack = AudioHijackPresence()
        let invoker = ShortcutInvoker()
        let ahController = AudioHijackController(
            prompter: SystemMeetingNamePrompter(),
            invoker: invoker,
            presence: audioHijack
        )
        let hotkey = HotkeyCoordinator(
            settings: settings,
            registrar: HotkeyRegistrar(),
            invoker: invoker,
            audioHijack: ahController,
            menuBar: menuBar,
            auditLog: auditLog
        )
        let loginItem = LoginItemController(manager: LoginItemManager())
        self._menuBar = State(initialValue: menuBar)
        self._settings = State(initialValue: settings)
        self._auditLog = State(initialValue: auditLog)
        self._pipeline = State(initialValue: pipeline)
        self._hotkey = State(initialValue: hotkey)
        self._loginItem = State(initialValue: loginItem)
        self._audioHijack = State(initialValue: audioHijack)
        self._audioHijackController = State(initialValue: ahController)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdown(menuBar: menuBar, pipeline: pipeline, hotkey: hotkey)
        } label: {
            MenuBarIconLabel(
                isRecording: menuBar.isRecording,
                pipelineState: menuBar.iconState
            )
        }
        .menuBarExtraStyle(.menu)

        Window(Self.appDisplayName, id: "main") {
            MainWindow()
                .environment(menuBar)
                .environment(settings)
                .environment(auditLog)
                .environment(pipeline)
                .environment(hotkey)
                .environment(loginItem)
                .environment(audioHijack)
                .environment(audioHijackController)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    await pipeline.bootstrap()
                    await hotkey.bootstrap()
                    // If the user had Launch on Startup enabled previously,
                    // reapply on launch so the registration is fresh (a
                    // freshly-installed binary might have a different code
                    // signature than the last registration).
                    if settings.launchOnStartup {
                        loginItem.apply(enabled: true)
                    }
                }
        }
        .windowResizability(.contentMinSize)
    }

    /// Resolves the user-visible app name from the bundle so the Window
    /// title shows "Jot" in Release and "Jot Dev" in Debug.
    static var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Jot"
    }
}

/// The menu-bar icon. Recording state takes precedence over pipeline
/// state — that's the user's most-immediate concern. When not recording,
/// we render the existing pipeline-state glyph.
///
/// macOS template-renders SF Symbols here so they pick up the menu bar's
/// adaptive color. For the recording case we use `.palette` rendering
/// with `.red` so the dot stays visible against any wallpaper.
private struct MenuBarIconLabel: View {
    let isRecording: Bool
    let pipelineState: PipelineState

    var body: some View {
        if isRecording {
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
        } else {
            pipelineIcon
        }
    }

    @ViewBuilder
    private var pipelineIcon: some View {
        switch pipelineState {
        case .notConfigured:
            // Distinct icon for Debug so the dev build is visually different
            // from the production install. Both renders are template-styled
            // by macOS to match the menu bar.
            #if DEBUG
            Image(systemName: "hammer")
            #else
            Image(systemName: "waveform.slash")
            #endif
        case .idle:
            #if DEBUG
            Image(systemName: "hammer")
            #else
            Image(systemName: "waveform")
            #endif
        case .processing:
            Image(systemName: "waveform.circle")
                .symbolEffect(.pulse, options: .repeating)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}

/// The dropdown shown when the menu-bar icon is clicked. Phase 8 replaces
/// this with click-to-toggle-window behavior on a custom `NSStatusItem`
/// (PRD §3.1 says "does not use a dropdown menu"); for now this gives the
/// user a way to surface the main window + see the current state inline.
private struct MenuBarDropdown: View {
    let menuBar: MenuBarController
    let pipeline: PipelineCoordinator
    let hotkey: HotkeyCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status row — recording state takes priority
        Text(menuBar.statusLine)
            .foregroundStyle(.secondary)

        Divider()

        // "Stop recording" only shown while AH is recording — gives the user
        // a click-to-stop path that doesn't require the hotkey.
        if menuBar.isRecording {
            Button("Stop recording") {
                Task { await hotkey.stopRecordingNow() }
            }
            Divider()
        }

        // "Dismiss error" only shown while the icon is red, so the menu
        // stays tidy in the normal case.
        if case .error = menuBar.iconState {
            Button("Dismiss error") {
                pipeline.dismissError()
            }
            Divider()
        }

        Button("Open \(JotApp.appDisplayName)") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")

        Divider()

        Button("Quit \(JotApp.appDisplayName)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
