import AppKit
import Foundation
import UniformTypeIdentifiers

/// Abstracts the file picker so the coordinator's flow is testable
/// without an NSOpenPanel.
@MainActor
protocol ManualUploadFilePicking: AnyObject {
    /// Show the picker and return the chosen URL, or nil if the user
    /// cancelled. The picker is responsible for filtering to the
    /// `.mp3`/`.mp4` UTTypes the coordinator supports.
    func pick() async -> URL?
}

/// Production picker: native `NSOpenPanel` filtered to `.mp3`/`.mp4`.
/// Single-file selection only (the PRD §3 explicitly defers bulk
/// upload). The panel is modal-to-window relative to whichever Jot
/// window is key when the user invokes it.
@MainActor
final class SystemManualUploadFilePicker: ManualUploadFilePicking {

    func pick() async -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Upload Recording"
        panel.message = "Pick a .mp3 audio file or a .mp4 video to transcribe."
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.mp3, .mpeg4Movie]

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }
}
