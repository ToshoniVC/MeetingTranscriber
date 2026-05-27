import SwiftUI
import AppKit

/// PRD §3.2 Tab 1 — file browser of the user's Output Folder. Each
/// successful transcription appears as a meeting folder (newest first)
/// containing the moved audio + the `.txt` transcript.
///
/// Live refresh: the view reads `AuditLogStore.entries.count` and uses it
/// as the `.task(id:)` trigger, so every new pipeline event (success or
/// failure) re-lists the folder without polling.
struct TranscriptsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AuditLogStore.self) private var auditLog
    @State private var viewModel = TranscriptsViewModel()

    /// Folder targeted for rename, plus the in-flight name draft. Drives the
    /// rename alert.
    @State private var renaming: MeetingFolder?
    @State private var renameDraft: String = ""

    /// Folder targeted for delete confirmation.
    @State private var confirmingDelete: MeetingFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: refreshKey) {
            await refresh()
        }
        .alert("Rename meeting folder", isPresented: renameAlertBinding) {
            TextField("New name", text: $renameDraft)
            Button("Rename") {
                if let target = renaming {
                    Task { await performRename(target: target, name: renameDraft) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) {
                renaming = nil
            }
        } message: {
            Text("Pick a new folder name. The `.mp3` and `.txt` files inside keep their current names.")
        }
        .alert("Move to Trash?", isPresented: deleteConfirmBinding) {
            Button("Move to Trash", role: .destructive) {
                if let target = confirmingDelete {
                    Task { await viewModel.moveToTrash(target.url) }
                }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                confirmingDelete = nil
            }
        } message: {
            if let folder = confirmingDelete {
                Text("'\(folder.name)' will be moved to your Trash.")
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Transcripts")
                .font(.title2.weight(.semibold))
            if viewModel.isLoading {
                ProgressView().controlSize(.small).padding(.leading, 6)
            }
            Spacer()
            if outputFolder != nil {
                Button {
                    if let url = outputFolder { viewModel.revealInFinder(url) }
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if outputFolder == nil {
            ContentUnavailableView(
                "No Output Folder",
                systemImage: "folder.badge.questionmark",
                description: Text("Pick an Output Folder in Settings to start seeing transcripts here.")
            )
        } else if let error = viewModel.lastError {
            ContentUnavailableView(
                "Couldn't read Output Folder",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if viewModel.meetings.isEmpty {
            ContentUnavailableView(
                "No transcripts yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Drop an audio file in your Watch Folder. Once it's transcribed, the meeting folder appears here.")
            )
        } else {
            List {
                ForEach(viewModel.meetings) { meeting in
                    MeetingFolderRow(
                        meeting: meeting,
                        onRevealFolder: { viewModel.revealInFinder(meeting.url) },
                        onOpenFile: { viewModel.openInDefaultApp($0) },
                        onRevealFile: { viewModel.revealInFinder($0) },
                        onRenameRequested: {
                            renameDraft = meeting.name
                            renaming = meeting
                        },
                        onDeleteRequested: {
                            confirmingDelete = meeting
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Refresh wiring

    /// Re-runs the `.task(id:)` whenever any of these change.
    private var refreshKey: RefreshKey {
        RefreshKey(
            outputFolder: settings.outputFolderBookmark,
            auditLogCount: auditLog.entries.count
        )
    }

    private func refresh() async {
        await viewModel.refresh(outputFolder: outputFolder)
    }

    /// Resolved Output Folder URL (security-scoped access acquired for the
    /// duration of this view's lifetime by the PipelineCoordinator when the
    /// pipeline is running; harmless if not running — the FS still lets us
    /// list).
    private var outputFolder: URL? {
        guard let data = settings.outputFolderBookmark else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    // MARK: - Alert bindings (Bool ↔ Optional state)

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(
            get: { confirmingDelete != nil },
            set: { if !$0 { confirmingDelete = nil } }
        )
    }

    private func performRename(target: MeetingFolder, name: String) async {
        _ = await viewModel.rename(target.url, to: name)
        await refresh()
    }
}

/// Composite key the `.task(id:)` modifier compares. Any change → refresh.
private struct RefreshKey: Equatable {
    let outputFolder: Data?
    let auditLogCount: Int
}
