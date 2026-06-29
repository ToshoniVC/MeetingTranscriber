import SwiftUI

/// PRD §3.2 Tab 2 — chronological list of pipeline events, plus a "Clear
/// Log" button. Failure rows have a Retry button that re-enqueues the
/// source file into the pipeline.
struct AuditLogView: View {
    @Environment(AuditLogStore.self) private var store
    @Environment(PipelineCoordinator.self) private var pipeline
    @Environment(ErrorInspector.self) private var inspector

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Text("Audit Log")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !store.entries.isEmpty {
                    Button(role: .destructive) {
                        store.clear()
                        // Also reset the menu-bar icon if it's still red
                        // from a previous failure — the user has acknowledged
                        // and cleared the slate.
                        pipeline.dismissError()
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()

            // Body
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "list.bullet.clipboard",
                    description: Text("Drop an audio file into your Watch Folder and watch this list fill up.")
                )
            } else {
                List(store.entries) { entry in
                    AuditLogRow(
                        entry: entry,
                        onRetry: {
                            Task { await pipeline.retry(entry: entry) }
                        },
                        onShowDetails: entry.kind == .failure
                            ? { inspector.show(from: entry) }
                            : nil,
                        onRetryNotion: retryNotionAction(for: entry),
                        onShowNotionDetails: notionDetailsAction(for: entry)
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// True when this row's Notion write ended in `.failed` — the only
    /// state that gets the Details + Retry Notion affordances.
    private func isNotionFailed(_ entry: AuditLogEntry) -> Bool {
        if case .failed = entry.notionStatus { return true }
        return false
    }

    /// Replay-just-Notion action for a row, or nil when its Notion write
    /// didn't fail or the row predates the on-disk retry payload (legacy
    /// entries with no `meetingFolderPath` can't be replayed, so they get
    /// Details only — no dead button). The explicit `(() -> Void)?` return
    /// type gives the closure a known shape so `Task { … }` resolves
    /// unambiguously.
    private func retryNotionAction(for entry: AuditLogEntry) -> (() -> Void)? {
        guard isNotionFailed(entry), entry.meetingFolderPath != nil else { return nil }
        return { Task { await pipeline.retryNotion(entry: entry) } }
    }

    /// Show-Notion-error action for a row, or nil when its Notion write
    /// didn't fail.
    private func notionDetailsAction(for entry: AuditLogEntry) -> (() -> Void)? {
        guard isNotionFailed(entry) else { return nil }
        return { inspector.show(notionFailureFrom: entry) }
    }
}
