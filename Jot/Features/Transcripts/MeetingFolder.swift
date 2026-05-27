import Foundation

/// A single meeting folder discovered in the user's Output Folder.
/// Produced by `FileOrganizer` (one per successful transcription) and
/// surfaced by the Transcripts tab.
///
/// Per PRD §3.2 Tab 1, the user-visible identity is the folder name; the
/// modification date powers sort order and the relative-time subtitle.
struct MeetingFolder: Identifiable, Equatable, Sendable {
    /// Folder URL — also serves as the stable identity for SwiftUI lists.
    let id: URL

    /// Last-modified date of the folder itself (newest-first sort key).
    let modifiedAt: Date

    /// Contents of the folder. Empty array means we couldn't read it.
    let files: [MeetingFile]

    var name: String { id.lastPathComponent }
    var url: URL { id }

    /// The `.txt` transcript, if one exists in this folder.
    var transcriptFile: MeetingFile? {
        files.first { $0.url.pathExtension.lowercased() == "txt" }
    }

    /// The audio file (mp3/m4a/wav), if one exists in this folder.
    var audioFile: MeetingFile? {
        files.first { SupportedAudioType.isCandidate($0.url) }
    }
}

/// A single file inside a `MeetingFolder` — usually the audio recording or
/// the transcript text. Other files (notes the user dropped in, etc.) also
/// show up.
struct MeetingFile: Identifiable, Equatable, Sendable {
    let id: URL
    let sizeBytes: Int64

    var url: URL { id }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    /// Human-readable size: "1.2 KB", "4.7 MB", etc.
    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
