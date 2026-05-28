import Foundation

/// Errors raised by the manual-upload pipeline (file picker → staging →
/// optional MP4-to-audio extraction → drop into Watch Folder). Each
/// carries a `userFacingMessage` so the Transcripts view + audit log
/// can surface them without parsing.
enum ManualUploadError: Error, Equatable {
    /// User dismissed the file picker or the metadata prompt.
    case userCancelled

    /// File extension wasn't in `ManualUploadMediaKind.allowedExtensions`.
    case unsupportedFormat(String)

    /// Picked URL no longer exists on disk (sandboxed bookmark stale, file
    /// moved between selection and staging).
    case fileNotFound(URL)

    /// Picked URL exists but `FileManager.isReadableFile` returned false.
    case unreadableFile(URL)

    /// Watch Folder bookmark missing or unresolvable. The pipeline can't
    /// receive a manual upload until Settings has a valid Watch Folder.
    case watchFolderUnreachable

    /// `FileManager.copyItem` into the Watch Folder failed.
    case stagingFailed(String)

    /// AVAssetExportSession failed for the `.mp4` → audio extraction.
    case conversionFailed(String)

    /// MP4 had no audio track.
    case noAudioTrack

    /// Meeting name was blank after trimming.
    case invalidMeetingName

    var userFacingMessage: String {
        switch self {
        case .userCancelled:
            return "Upload cancelled."
        case .unsupportedFormat(let ext):
            let label = ext.isEmpty ? "(no extension)" : ".\(ext)"
            return "Unsupported format \(label). Only .mp3 and .mp4 files can be uploaded."
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)."
        case .unreadableFile(let url):
            return "Can't read file: \(url.lastPathComponent)."
        case .watchFolderUnreachable:
            return "Watch Folder isn't set or can't be reached. Pick one in Settings before uploading."
        case .stagingFailed(let message):
            return "Couldn't copy the file into the Watch Folder: \(message)."
        case .conversionFailed(let message):
            return "Couldn't extract audio from the video: \(message)."
        case .noAudioTrack:
            return "The selected video doesn't contain an audio track."
        case .invalidMeetingName:
            return "Meeting name is required."
        }
    }
}
