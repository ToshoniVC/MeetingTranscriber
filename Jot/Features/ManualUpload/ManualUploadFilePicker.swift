import AppKit
import Foundation
import UniformTypeIdentifiers

/// Abstracts the file picker so the coordinator's flow is testable
/// without an NSOpenPanel.
@MainActor
protocol ManualUploadFilePicking: AnyObject {
    /// Show the picker and return the chosen URLs, or an empty array if
    /// the user cancelled. Multi-select is supported since v0.5.1 — the
    /// coordinator treats N>1 selections as a single multi-part meeting
    /// (one Notion page, merged timestamps), N==1 takes the existing
    /// single-file path. The picker is responsible for filtering to the
    /// `.mp3`/`.mp4` UTTypes the coordinator supports.
    func pick() async -> [URL]
}

/// Production picker: native `NSOpenPanel` filtered to `.mp3`/`.mp4`.
/// v0.5.1 enables multi-select so the user can lift an Audio Hijack
/// split recording (or any group of clips they want treated as one
/// meeting) in a single gesture. The panel is modal-to-window relative
/// to whichever Jot window is key when the user invokes it.
@MainActor
final class SystemManualUploadFilePicker: ManualUploadFilePicking {

    func pick() async -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Upload Recording"
        panel.message = "Pick one or more .mp3 / .m4a / .wav / .mp4 files. Multiple files become one meeting."
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        // v0.5.3 expanded from mp3+mp4 to also accept m4a and wav —
        // mirrors the existing watcher's `SupportedAudioType`, and
        // unblocks the workaround for the Audio Hijack split-MP3 +
        // Whisper-can't-decode case (users re-encode to m4a via
        // `afconvert` and then need a way to upload the result).
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .mpeg4Movie]

        let response = panel.runModal()
        guard response == .OK else { return [] }
        // Sort by filename so the user's natural ordering ("part 1.mp3",
        // "part 2.mp3", …) lines up with the chronological order the
        // batch accumulator + Whisper see at processing time.
        return panel.urls.sorted { a, b in
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }
}
