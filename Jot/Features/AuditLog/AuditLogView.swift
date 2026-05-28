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
                            Task { await pipeline.retry(url: URL(fileURLWithPath: entry.sourcePath)) }
                        },
                        onShowDetails: entry.kind == .failure
                            ? { inspector.show(from: entry) }
                            : nil
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
