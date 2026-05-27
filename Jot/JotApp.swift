import SwiftUI
import AppKit

/// The Jot app entry point.
///
/// Declares two scenes:
/// - `MenuBarExtra`: the always-visible menu-bar icon. Phase 0 uses the
///   default `.menu` style with an "Open Jot" action. Phase 8 (icon state
///   machine + UI polish) replaces this with a custom `NSStatusItem` so a
///   single click toggles the main window directly (no dropdown) per PRD §3.1.
/// - `Window`: the main application window with the three PRD tabs.
///   `MainWindow` (Core/App) owns the layout and routing.
///
/// Per Claude/coding-instructions.md §2 (Feature-Driven Design), the app
/// scene lives in the target's root, not under any feature folder.
@main
struct JotApp: App {
    @State private var menuBar = MenuBarController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdown()
        } label: {
            // Distinct icon for Debug so the dev build is visually different
            // in the menu bar from the production install (PRD-supporting per
            // development-lifecycle.md §2: "tinted icon for the dev variant").
            // Both renders are template-styled by macOS to match the menu bar.
            #if DEBUG
            Image(systemName: "hammer")
            #else
            Image(systemName: "waveform")
            #endif
        }
        .menuBarExtraStyle(.menu)

        Window(Self.appDisplayName, id: "main") {
            MainWindow()
                .environment(menuBar)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
    }

    /// Resolves the user-visible app name from the bundle's `CFBundleName`,
    /// so the production build shows "Jot" and the Debug build shows "Jot Dev"
    /// without any `#if DEBUG` ceremony at the call sites.
    static var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Jot"
    }
}

/// Phase 0 placeholder dropdown shown when the menu-bar icon is clicked.
///
/// Phase 8 replaces this with click-to-toggle-window behavior on a custom
/// `NSStatusItem`. Until then, "Open <AppName>" gives the user a way to
/// surface the main window.
private struct MenuBarDropdown: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open \(JotApp.appDisplayName)") {
            openWindow(id: "main")
            // LSUIElement=YES apps are "background" by default — `openWindow`
            // surfaces the window but leaves Jot behind the currently-active
            // app. Activate explicitly so the window comes to the front and
            // Jot becomes the focused app.
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
