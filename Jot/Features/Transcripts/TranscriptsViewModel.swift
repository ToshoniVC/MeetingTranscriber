import Foundation
import Observation
import AppKit

/// View-model for the Transcripts tab. Owns the file-system listing and the
/// per-row file actions (reveal in Finder, open, rename, delete-to-trash).
///
/// Pure-ish: file I/O happens via `FileManager` / `NSWorkspace` so tests can
/// either inject a fake `FileManager` or operate against a real tmpdir.
@MainActor
@Observable
final class TranscriptsViewModel {

    /// Meeting folders found in the Output Folder, newest-first. Empty when
    /// no Output Folder is configured or it's empty.
    private(set) var meetings: [MeetingFolder] = []

    /// One-line user-facing error if the last refresh failed (folder
    /// unreachable, permission denied, etc.). Cleared on successful refresh.
    private(set) var lastError: String?

    /// True while a refresh is in flight. Used by the view to show a
    /// progress indicator.
    private(set) var isLoading: Bool = false

    /// Injected so tests can substitute a hermetic FS layer if they want.
    /// Production uses `.default`.
    private let fileManager: FileManager

    /// Injected so tests can capture the user-facing actions without
    /// actually calling `NSWorkspace` / putting files in the system trash.
    private let workspace: WorkspaceActions

    init(
        fileManager: FileManager = .default,
        workspace: WorkspaceActions = SystemWorkspaceActions()
    ) {
        self.fileManager = fileManager
        self.workspace = workspace
    }

    // MARK: - Refresh

    /// Re-read the Output Folder. Safe to call repeatedly — the view triggers
    /// this on appear and whenever the audit log's entry count changes
    /// (indirect signal that the pipeline did something).
    func refresh(outputFolder: URL?) async {
        guard let folder = outputFolder else {
            meetings = []
            lastError = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let listed = try await Task.detached { [fileManager] in
                try Self.listMeetingFolders(in: folder, using: fileManager)
            }.value
            meetings = listed
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.pipeline.warning("TranscriptsViewModel refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Actions

    /// Reveal the file (or folder) in Finder with the item pre-selected.
    func revealInFinder(_ url: URL) {
        workspace.revealInFinder(url)
    }

    /// Open the file in its default app (e.g., `.txt` → TextEdit / VS Code).
    func openInDefaultApp(_ url: URL) {
        workspace.openInDefaultApp(url)
    }

    /// Move the meeting folder to the user's Trash. Returns true on success.
    @discardableResult
    func moveToTrash(_ url: URL) async -> Bool {
        do {
            try await Task.detached { [fileManager] in
                var resulting: NSURL? = nil
                try fileManager.trashItem(at: url, resultingItemURL: &resulting)
            }.value
            // Update local listing so the row vanishes immediately, without
            // waiting for the next refresh tick. Compare by `.path` (not URL
            // equality) so directory-trailing-slash and symlink variants
            // (`/var` vs `/private/var`) don't cause us to miss the match.
            let target = url.resolvingSymlinksInPath().path(percentEncoded: false)
            meetings.removeAll {
                $0.id.resolvingSymlinksInPath().path(percentEncoded: false) == target
            }
            return true
        } catch {
            lastError = "Could not move to Trash: \(error.localizedDescription)"
            return false
        }
    }

    /// Rename a meeting folder. Returns the new URL on success, nil on
    /// failure (with `lastError` populated).
    @discardableResult
    func rename(_ url: URL, to newName: String) async -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Name cannot be empty."
            return nil
        }
        // Reject path separators outright — these would either silently move
        // the folder somewhere unexpected or fail in a confusing way.
        if trimmed.contains("/") || trimmed.contains(":") {
            lastError = "Name cannot contain '/' or ':'."
            return nil
        }

        let newURL = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if fileManager.fileExists(atPath: newURL.path(percentEncoded: false)) {
            lastError = "A folder named '\(trimmed)' already exists here."
            return nil
        }
        do {
            try await Task.detached { [fileManager] in
                try fileManager.moveItem(at: url, to: newURL)
            }.value
            return newURL
        } catch {
            lastError = "Could not rename: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Listing

    /// Discover meeting folders inside `outputFolder`. Returns them sorted
    /// newest-first. Hidden files / non-directory entries are skipped.
    ///
    /// `nonisolated` so it can be called from `Task.detached` (off-main),
    /// keeping the UI responsive while the FS walk happens.
    nonisolated static func listMeetingFolders(
        in outputFolder: URL,
        using fileManager: FileManager
    ) throws -> [MeetingFolder] {
        let contents = try fileManager.contentsOfDirectory(
            at: outputFolder,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        let meetings: [MeetingFolder] = contents.compactMap { folderURL in
            let resolved = folderURL.resolvingSymlinksInPath()
            let values = try? resolved.resourceValues(forKeys: [
                .isDirectoryKey, .contentModificationDateKey
            ])
            guard values?.isDirectory == true else { return nil }
            let mtime = values?.contentModificationDate ?? .distantPast

            let files = (try? Self.listFiles(in: resolved, using: fileManager)) ?? []
            return MeetingFolder(id: resolved, modifiedAt: mtime, files: files)
        }

        return meetings.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// List the immediate files inside a meeting folder (no subdirectory
    /// descent). Hidden files are skipped. Nonisolated so the recursive
    /// call from `listMeetingFolders` works off-main too.
    nonisolated private static func listFiles(
        in folderURL: URL,
        using fileManager: FileManager
    ) throws -> [MeetingFile] {
        let contents = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return contents.compactMap { fileURL in
            let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey
            ])
            guard values?.isRegularFile == true else { return nil }
            let size = Int64(values?.fileSize ?? 0)
            return MeetingFile(id: fileURL, sizeBytes: size)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Workspace abstraction

/// Workspace operations we want to substitute in tests so calls don't reach
/// the real system Finder / default-app launcher.
protocol WorkspaceActions: Sendable {
    func revealInFinder(_ url: URL)
    func openInDefaultApp(_ url: URL)
}

/// Production implementation backed by `NSWorkspace`.
struct SystemWorkspaceActions: WorkspaceActions {
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
