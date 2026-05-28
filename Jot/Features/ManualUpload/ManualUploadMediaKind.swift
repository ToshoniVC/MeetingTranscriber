import Foundation

/// What kind of media the user picked. Drives the branch between "drop
/// straight into Watch Folder" (audio) and "extract audio first" (video).
///
/// The PRD asks for `.mp3` and `.mp4`. For `.mp4` we extract audio as
/// `.m4a` via AVFoundation's `AppleM4A` preset rather than re-encoding
/// to `.mp3` — `SupportedAudioType` already accepts `.m4a` and the
/// transcription endpoints don't care about the container suffix, so
/// the user-visible result is identical and we avoid bundling an MP3
/// encoder.
enum ManualUploadMediaKind: Sendable, Equatable {
    /// Drop directly into the Watch Folder, no conversion.
    case audioMP3

    /// Run through `MediaConversionService` to produce a `.m4a`, then drop
    /// the converted file into the Watch Folder.
    case videoMP4

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "mp3": self = .audioMP3
        case "mp4": self = .videoMP4
        default: return nil
        }
    }

    static let allowedExtensions: [String] = ["mp3", "mp4"]
}
