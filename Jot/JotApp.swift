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

    init() {
        let menuBar = MenuBarController()
        let settings = AppSettings()
        let auditLog = AuditLogStore()
        let pipeline = PipelineCoordinator(
            settings: settings,
            auditLog: auditLog,
            menuBar: menuBar
        )
        self._menuBar = State(initialValue: menuBar)
        self._settings = State(initialValue: settings)
        self._auditLog = State(initialValue: auditLog)
        self._pipeline = State(initialValue: pipeline)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdown(menuBar: menuBar)
        } label: {
            MenuBarIconLabel(state: menuBar.iconState)
        }
        .menuBarExtraStyle(.menu)

        Window(Self.appDisplayName, id: "main") {
            MainWindow()
                .environment(menuBar)
                .environment(settings)
                .environment(auditLog)
                .environment(pipeline)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    await pipeline.bootstrap()
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

/// The menu-bar icon — derived from `MenuBarController.iconState`.
///
/// macOS template-renders SF Symbols here so they pick up the menu bar's
/// adaptive color. We change the *glyph* per state and add a pulse animation
/// for processing.
private struct MenuBarIconLabel: View {
    let state: PipelineState

    var body: some View {
        switch state {
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status row
        Text(menuBar.statusLine)
            .foregroundStyle(.secondary)

        Divider()

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
