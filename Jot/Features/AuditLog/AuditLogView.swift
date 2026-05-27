import SwiftUI

/// Phase 0 placeholder for the Audit Log tab.
///
/// Phase 5 (Claude/implementation-plan.md §6) replaces this with the real
/// chronological event log per PRD §3.2 Tab 2 — persisted to disk via
/// `AuditLogStore`, with "Retry" buttons on failure rows and a "Clear Log"
/// button.
struct AuditLogView: View {
    var body: some View {
        ContentUnavailableView(
            "Audit Log",
            systemImage: "list.bullet.clipboard",
            description: Text("Pipeline events (successes, failures, retries) will appear here.\n(Implementation lands in Phase 5.)")
        )
    }
}
