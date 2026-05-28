import Foundation

/// Validates a user-picked media file and copies the (possibly converted)
/// result into the Watch Folder so the existing `FolderWatcher` →
/// `ProcessingPipeline` chain picks it up as if Audio Hijack had just
/// produced a recording. The watcher's `FileReadinessDetector` then
/// debounces the new file for `stableDuration` seconds before emitting
/// it on the stream.
///
/// Pure file operations: no UI, no actors, no global state. Safe to call
/// from any context that has security-scoped access to the Watch Folder.
struct ManualUploadStagingService: Sendable {

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Validate that `url` is a supported media file we can read. Throws
    /// the relevant `ManualUploadError` otherwise. Returns the resolved
    /// `ManualUploadMediaKind` so the caller knows whether to invoke
    /// `MediaConversionService` before staging.
    func validate(_ url: URL) throws -> ManualUploadMediaKind {
        let ext = url.pathExtension
        guard let kind = ManualUploadMediaKind(fileExtension: ext) else {
            throw ManualUploadError.unsupportedFormat(ext)
        }
        let path = url.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else {
            throw ManualUploadError.fileNotFound(url)
        }
        guard fileManager.isReadableFile(atPath: path) else {
            throw ManualUploadError.unreadableFile(url)
        }
        return kind
    }

    /// Copy `source` into `watchFolder`. The copied filename keeps the
    /// source basename, with `-2`, `-3`, … suffixed on collision so a
    /// repeat upload of the same file doesn't clobber the previous one.
    /// Returns the destination URL.
    ///
    /// Copy (not move) is intentional: the user picked a file from
    /// somewhere outside Jot's control, and we don't want to remove
    /// their original. `FolderWatcher` is responsible for moving the
    /// staged file into the meeting folder after a successful
    /// transcription; that move happens on the copy we placed.
    func stage(source: URL, into watchFolder: URL) throws -> URL {
        let folderPath = watchFolder.path(percentEncoded: false)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: folderPath, isDirectory: &isDir),
              isDir.boolValue else {
            throw ManualUploadError.watchFolderUnreachable
        }
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let target = uniqueURL(under: watchFolder, baseName: baseName, ext: ext)
        do {
            try fileManager.copyItem(at: source, to: target)
            return target
        } catch {
            throw ManualUploadError.stagingFailed(error.localizedDescription)
        }
    }

    /// First free URL of the form `<parent>/<baseName>.<ext>` /
    /// `<parent>/<baseName>-2.<ext>` / … Mirrors the collision strategy
    /// used by `FileOrganizer.uniqueFolderURL` and
    /// `ProcessingPipeline.uniqueAudioURL` so the on-disk layout reads
    /// consistently regardless of which subsystem created the file.
    func uniqueURL(under parent: URL, baseName: String, ext: String) -> URL {
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"
        let direct = parent.appendingPathComponent("\(baseName)\(extSuffix)")
        if !fileManager.fileExists(atPath: direct.path(percentEncoded: false)) {
            return direct
        }
        for suffix in 2...999 {
            let candidate = parent.appendingPathComponent("\(baseName)-\(suffix)\(extSuffix)")
            if !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return parent.appendingPathComponent("\(baseName)-\(UUID().uuidString.prefix(8))\(extSuffix)")
    }
}
