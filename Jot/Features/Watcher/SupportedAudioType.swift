import Foundation

/// Audio file extensions the watcher considers candidate inputs.
///
/// PRD §4.1 requires `.mp3`, `.m4a`, and `.wav`. Anything else (including
/// hidden files and the in-progress temp extensions Audio Hijack uses while
/// it's still writing, like `.tmp` and `.partial`) is ignored.
enum SupportedAudioType: String, CaseIterable, Sendable {
    case mp3
    case m4a
    case wav

    /// True if `url`'s last path component is a candidate audio file the
    /// watcher should consider. Returns `false` for:
    ///   - hidden files (filename starts with ".")
    ///   - files whose extension isn't in the supported set
    ///   - typical "still writing" extensions (.tmp, .partial, .crdownload)
    static func isCandidate(_ url: URL) -> Bool {
        let filename = url.lastPathComponent
        if filename.isEmpty || filename.hasPrefix(".") {
            return false
        }
        let ext = url.pathExtension.lowercased()
        return SupportedAudioType(rawValue: ext) != nil
    }
}
