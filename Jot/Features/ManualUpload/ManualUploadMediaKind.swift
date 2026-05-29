import Foundation

/// What kind of media the user picked. Drives the branch between "drop
/// straight into Watch Folder" (audio) and "extract audio first" (video).
///
/// v0.5.0 shipped with mp3 + mp4. v0.5.3 adds m4a + wav so Manual
/// Upload mirrors the audio formats the watcher already supports
/// (`SupportedAudioType`). The motivating case: Audio Hijack split
/// MP3s that Whisper's server-side decoder rejects ("audio file could
/// not be decoded") even when local players read them fine — users
/// have to re-encode to m4a via `afconvert` and then need a way to
/// upload the result.
///
/// For `.mp4` we extract audio as `.m4a` via AVFoundation's
/// `AppleM4A` preset rather than re-encoding to `.mp3`. The endpoints
/// don't care about the container suffix and we avoid bundling an
/// MP3 encoder.
enum ManualUploadMediaKind: Sendable, Equatable {
    /// Drop directly into the Watch Folder, no conversion. Covers
    /// `.mp3`, `.m4a`, and `.wav`.
    case audio

    /// Run through `MediaConversionService` to produce a `.m4a`, then
    /// drop the converted file into the Watch Folder.
    case videoMP4

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "mp3", "m4a", "wav": self = .audio
        case "mp4": self = .videoMP4
        default: return nil
        }
    }

    static let allowedExtensions: [String] = ["mp3", "m4a", "wav", "mp4"]
}
