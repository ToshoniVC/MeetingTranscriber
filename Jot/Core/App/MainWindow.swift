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
    @Environment(ErrorInspector.self) private var inspector
    @Environment(SparkleUpdater.self) private var updater

    var body: some View {
        @Bindable var inspectorBinding = inspector

        NavigationSplitView {
            // Sidebar = list of tabs (top) + version footer (bottom).
            // Wrapping in a VStack lets the footer sit below the List
            // without pushing the rows around.
            VStack(spacing: 0) {
                List(MainTab.allCases, selection: $selection) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
                .navigationTitle("Jot")

                Divider()

                SidebarVersionFooter(
                    pendingUpdate: updater.pendingUpdateVersion,
                    onUpdateTapped: { updater.checkForUpdates() }
                )
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            switch selection {
            case .transcripts: TranscriptsView()
            case .auditLog:    AuditLogView()
            case .settings:    SettingsView()
            }
        }
        // Single error-inspector sheet hosted at the window level so it
        // appears regardless of which tab is in front. `.sheet(item:)`
        // shows when `currentError` is non-nil and hides when it's nil.
        .sheet(item: $inspectorBinding.currentError) { details in
            ErrorInspectorView(
                details: details,
                onDismiss: { inspector.dismiss() },
                onOpenAuditLog: {
                    selection = .auditLog
                    inspector.dismiss()
                }
            )
        }
    }
}

/// Pinned to the bottom of the sidebar. Always shows the running
/// version; surfaces an "Update available" row when Sparkle's background
/// check has discovered a newer appcast entry. Clicking the update row
/// re-triggers `checkForUpdates()` which re-presents Sparkle's standard
/// dialog so the user can choose Install / Later / Skip.
private struct SidebarVersionFooter: View {
    /// `nil` when Jot is up to date or the check hasn't run yet.
    let pendingUpdate: String?
    let onUpdateTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Jot v\(AppVersion.marketing)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Build \(AppVersion.build)")

            if let version = pendingUpdate {
                Button(action: onUpdateTapped) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update available: v\(version)")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Click to open the updater")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
