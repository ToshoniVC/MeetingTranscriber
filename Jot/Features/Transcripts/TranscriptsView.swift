import SwiftUI

/// Phase 0 placeholder for the Transcripts tab.
///
/// Phase 6 (Claude/implementation-plan.md §7) replaces this with a real file
/// browser of the user's Output Folder per PRD §3.2 Tab 1 — list of meeting
/// folders, double-click to expand, right-click for reveal/delete/rename, live
/// refresh on pipeline success.
///
/// For Phase 0 we show a stable empty state so navigation routing in
/// `MainWindow` can be wired and tested end-to-end.
struct TranscriptsView: View {
    var body: some View {
        ContentUnavailableView(
            "Transcripts",
            systemImage: "doc.text",
            description: Text("Your meeting transcripts will appear here.\n(Implementation lands in Phase 6.)")
        )
    }
}
