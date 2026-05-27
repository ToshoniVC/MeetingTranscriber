import SwiftUI
import AppKit

/// PRD §3.2 Tab 3 → Folder Configuration:
/// - Watch Folder: where Audio Hijack drops recordings.
/// - Output Folder: where Jot files the per-meeting folders (audio + transcript).
///
/// Phase 1 stores security-scoped bookmark data in `AppSettings` so access
/// survives relaunch (necessary under the sandbox that lands in Phase 8 —
/// even outside the sandbox we use bookmarks consistently so the transition
/// is a no-op).
struct FoldersSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        SectionHeader(
            title: "Folders",
            systemImage: "folder",
            subtitle: "Watch is where Audio Hijack writes. Output is where each meeting folder is created."
        )

        VStack(alignment: .leading, spacing: 16) {
            FolderPickerRow(
                label: "Watch Folder",
                bookmark: settings.watchFolderBookmark,
                onPick: { settings.watchFolderBookmark = $0 },
                onClear: { settings.watchFolderBookmark = nil }
            )

            FolderPickerRow(
                label: "Output Folder",
                bookmark: settings.outputFolderBookmark,
                onPick: { settings.outputFolderBookmark = $0 },
                onClear: { settings.outputFolderBookmark = nil }
            )

            if let watch = settings.watchFolderBookmark,
               let output = settings.outputFolderBookmark,
               watch == output {
                Label("Watch and Output folders must be different.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }
}

/// A single labeled folder picker: "Choose…" / "Clear" buttons, with the
/// resolved path shown when a bookmark is set.
private struct FolderPickerRow: View {
    let label: String
    let bookmark: Data?
    let onPick: (Data) -> Void
    let onClear: () -> Void

    var body: some View {
        LabeledField(label: label) {
            HStack(spacing: 8) {
                Text(displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(bookmark == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose…") {
                    if let data = chooseFolder() {
                        onPick(data)
                    }
                }

                Button("Clear", role: .destructive) {
                    onClear()
                }
                .disabled(bookmark == nil)
            }
        }
    }

    private var displayPath: String {
        guard let bookmark else { return "Not set" }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return "(could not resolve bookmark)"
        }
        return url.path(percentEncoded: false)
    }

    /// Opens a folder picker. Returns security-scoped bookmark data on
    /// success, `nil` if the user cancelled.
    private func chooseFolder() -> Data? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // Briefly acquire scoped access just to create the bookmark; release
        // immediately afterward to avoid holding a counter across the call.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        return try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
