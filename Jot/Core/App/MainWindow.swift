import SwiftUI

/// Root view for Jot's main window. Hosts a `NavigationSplitView` with the
/// three tabs declared by PRD §3.2: **Transcripts** (default), **Audit Log**,
/// **Settings**. Each tab's implementation lives in its own `Features/<name>/`
/// folder per Claude/coding-instructions.md §2 (Feature-Driven Design).
///
/// Phase 0 ships placeholder views in each feature folder; real UI lands later
/// (Phase 1 for Settings, Phase 5 for Audit Log, Phase 6 for Transcripts).
struct MainWindow: View {
    @State private var selection: MainTab = .transcripts

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationTitle("Jot")
            .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 240)
        } detail: {
            switch selection {
            case .transcripts: TranscriptsView()
            case .auditLog:    AuditLogView()
            case .settings:    SettingsView()
            }
        }
    }
}

/// The three top-level tabs of the main window.
///
/// Defined in `Core/App/` because the routing is app-wide infrastructure
/// (shared by `MainWindow` and, in Phase 8, the menu-bar icon's "open to tab"
/// behavior). Each tab's *content* belongs in its own feature folder.
enum MainTab: String, CaseIterable, Identifiable {
    case transcripts
    case auditLog
    case settings

    var id: Self { self }

    /// User-visible tab title. Changing these strings is a UI contract change —
    /// see `MainTabTests.titles_areStable` for the test that catches accidents.
    var title: String {
        switch self {
        case .transcripts: return "Transcripts"
        case .auditLog:    return "Audit Log"
        case .settings:    return "Settings"
        }
    }

    /// SF Symbol name shown in the sidebar list.
    var systemImage: String {
        switch self {
        case .transcripts: return "doc.text"
        case .auditLog:    return "list.bullet.clipboard"
        case .settings:    return "gearshape"
        }
    }
}
