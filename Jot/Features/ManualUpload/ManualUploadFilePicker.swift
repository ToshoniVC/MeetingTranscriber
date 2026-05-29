import AppKit
import Foundation
import RegexBuilder
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
        // Sort so the user's natural ordering lines up with the
        // chronological order the batch accumulator + Whisper see at
        // processing time. Primary key is the Audio Hijack-style part
        // number (1 for the bare filename, 2/3/… for "(part N)"
        // suffixes) — without this the bare `meeting.mp3` (first part)
        // sorts AFTER `meeting (part 2).mp3 … meeting (part 10).mp3`
        // because ASCII space (0x20) < period (0x2E), and the meeting
        // ends up reading out of order in the merged JSON / Notion
        // page. Secondary key is `localizedStandardCompare` so two
        // files that share a part number (or follow a completely
        // different naming scheme) still sort sensibly.
        return panel.urls.sorted { a, b in
            let aN = Self.audioHijackPartNumber(forFilename: a.lastPathComponent)
            let bN = Self.audioHijackPartNumber(forFilename: b.lastPathComponent)
            if aN != bN { return aN < bN }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: - Audio Hijack part-number detection

    /// Extract the Audio Hijack split-part number from a filename, or
    /// return `1` when there's no recognisable suffix. AH names a split
    /// recording as `<basename>.<ext>` for the first part and
    /// `<basename> (part N).<ext>` for parts 2..N — treating "no
    /// suffix" as part 1 makes the picker's sort line up with the
    /// actual recording order.
    ///
    /// Pure function, `nonisolated` + static so the unit tests can hit
    /// it directly without standing up an `NSOpenPanel`.
    nonisolated static func audioHijackPartNumber(forFilename name: String) -> Int {
        // Strip extension(s) first so files staged as `.m4a` (post-
        // v0.5.4 MP3 normalisation) still match against the AH naming.
        let stem = (name as NSString).deletingPathExtension
        // Regex for trailing " (part N)" where N is one or more digits.
        // Bounded with `$` so a similar-but-mid-name token doesn't fire
        // false matches.
        let pattern = Regex {
            " (part "
            Capture { OneOrMore(.digit) }
            ")"
            Anchor.endOfSubject
        }
        if let match = stem.firstMatch(of: pattern), let n = Int(match.output.1) {
            return n
        }
        return 1
    }
}
