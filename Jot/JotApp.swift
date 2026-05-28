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
    @State private var organizations: OrganizationStore
    @State private var meetingContextStore: MeetingContextStore
    @State private var pipeline: PipelineCoordinator
    @State private var hotkey: HotkeyCoordinator
    @State private var loginItem: LoginItemController
    @State private var audioHijack: AudioHijackPresence
    @State private var audioHijackController: AudioHijackController
    @State private var errorInspector: ErrorInspector
    @State private var debugMode: DebugMode
    @State private var updater: SparkleUpdater

    init() {
        let menuBar = MenuBarController()
        let settings = AppSettings()
        let auditLog = AuditLogStore()
        let organizations = OrganizationStore()
        // Shared between HotkeyCoordinator (stamps started/stopped/edits)
        // and PipelineCoordinator (queries it when a new file lands to
        // pull the meeting name + compiled context).
        let meetingContextStore = MeetingContextStore()
        let pipeline = PipelineCoordinator(
            settings: settings,
            auditLog: auditLog,
            menuBar: menuBar,
            meetingContextStore: meetingContextStore
        )
        let audioHijack = AudioHijackPresence()
        let invoker = ShortcutInvoker()
        let ahController = AudioHijackController(
            prompter: SystemMeetingStartPrompter(),
            invoker: invoker,
            presence: audioHijack
        )
        let hotkey = HotkeyCoordinator(
            settings: settings,
            registrar: HotkeyRegistrar(),
            invoker: invoker,
            audioHijack: ahController,
            menuBar: menuBar,
            auditLog: auditLog,
            organizations: organizations,
            meetingContextStore: meetingContextStore
        )
        let loginItem = LoginItemController(manager: LoginItemManager())
        let errorInspector = ErrorInspector()
        let debugMode = DebugMode()
        let updater = SparkleUpdater()
        self._menuBar = State(initialValue: menuBar)
        self._settings = State(initialValue: settings)
        self._auditLog = State(initialValue: auditLog)
        self._organizations = State(initialValue: organizations)
        self._meetingContextStore = State(initialValue: meetingContextStore)
        self._pipeline = State(initialValue: pipeline)
        self._hotkey = State(initialValue: hotkey)
        self._loginItem = State(initialValue: loginItem)
        self._audioHijack = State(initialValue: audioHijack)
        self._audioHijackController = State(initialValue: ahController)
        self._errorInspector = State(initialValue: errorInspector)
        self._debugMode = State(initialValue: debugMode)
        self._updater = State(initialValue: updater)

        // Bootstrap at process launch, not at MainWindow appearance.
        // LSUIElement = YES means launching as a Login Item never opens the
        // main window, so a `.task` on the window's content would never fire
        // and the menu-bar icon would sit at .notConfigured until the user
        // manually opened the window.
        Task { @MainActor in
            await pipeline.bootstrap()
            await hotkey.bootstrap()
            if settings.launchOnStartup {
                loginItem.apply(enabled: true)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdown(
                menuBar: menuBar,
                pipeline: pipeline,
                hotkey: hotkey,
                errorInspector: errorInspector,
                debugMode: debugMode
            )
            .environment(meetingContextStore)
            .environment(organizations)
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
                .environment(organizations)
                .environment(meetingContextStore)
                .environment(pipeline)
                .environment(hotkey)
                .environment(loginItem)
                .environment(audioHijack)
                .environment(audioHijackController)
                .environment(errorInspector)
                .environment(debugMode)
                .environment(updater)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentMinSize)

        // Phase E: floating editor for the currently-recording meeting's
        // metadata. Opened from the menu-bar dropdown via openWindow(id:).
        // Auto-closes when the recording ends (pending becomes nil) —
        // handled inside `CurrentMeetingEditorView`.
        Window("Current meeting", id: "current-meeting-editor") {
            CurrentMeetingEditorView()
                .environment(meetingContextStore)
                .environment(organizations)
        }
        .windowResizability(.contentSize)
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
    let errorInspector: ErrorInspector
    let debugMode: DebugMode
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status row — recording state takes priority
        Text(menuBar.statusLine)
            .foregroundStyle(.secondary)

        Divider()

        // "Stop recording" + "Edit current meeting…" only shown while AH is
        // recording — both require an active session to be useful.
        if menuBar.isRecording {
            Button("Edit current meeting…") {
                openWindow(id: "current-meeting-editor")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Stop recording") {
                Task { await hotkey.stopRecordingNow() }
            }
            Divider()
        }

        // Error-state actions: show details (opens the inspector modal in
        // the main window) and dismiss. Both only visible while the icon
        // is red, so the menu stays tidy in the normal case.
        if case .error = menuBar.iconState {
            Button("Show error details…") {
                errorInspector.show(pipelineState: menuBar.iconState)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
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

        // Developer submenu — keeps the rest of the dropdown clean for
        // normal use. The verbose-mode toggle and developer affordances
        // (Open Console, copy log command) live here.
        Menu("Developer") {
            Button(debugMode.isVerbose ? "Verbose logging: ON" : "Verbose logging: OFF") {
                debugMode.toggle()
            }
            if debugMode.isVerbose {
                Divider()
                Button("Open Console.app") {
                    openConsoleApp()
                }
                Button("Copy 'log show' command") {
                    copyLogShowCommand()
                }
            }
        }

        Divider()

        Button("Quit \(JotApp.appDisplayName)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openConsoleApp() {
        let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(consoleURL)
    }

    private func copyLogShowCommand() {
        // Pre-built command the user can paste into Terminal. Streams the
        // last 30 minutes of os.Logger output filtered to Jot's subsystem.
        let cmd = #"log show --predicate 'subsystem == "com.toshonivc.jot"' --info --debug --last 30m"#
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }
}
