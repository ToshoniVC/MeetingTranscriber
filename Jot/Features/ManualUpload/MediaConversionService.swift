import Foundation
@preconcurrency import AVFoundation

/// Re-encodes any audio-bearing input to `.m4a` (AAC) at a caller-
/// supplied destination. Uses `AVAssetExportSession` with the
/// `AppleM4A` preset — native, no external binary dependency. The
/// `FolderWatcher` already accepts `.m4a` (see `SupportedAudioType`), so
/// the resulting file flows through the existing pipeline unchanged.
///
/// **Two callers, same underlying operation:**
/// 1. **MP4 → m4a** (v0.5.0): extract the audio track from a video and
///    drop the result into the Watch Folder.
/// 2. **MP3 → m4a** (v0.5.4): normalise an uploaded MP3 to dodge the
///    Audio-Hijack-split-MP3 / Whisper-can't-decode case. Audio Hijack
///    writes split parts whose ID3/Xing metadata trips OpenAI's
///    server-side decoder ("audio file could not be decoded"), even
///    when local players + macOS's `afinfo` handle them fine.
///    Re-encoding via AVAssetExportSession produces a clean AAC-in-m4a
///    file that every endpoint accepts.
///
/// AVFoundation has no native MP3 encoder, so we don't bother trying to
/// stay in the MP3 container — m4a/AAC is what AVFoundation does well
/// and what every transcription endpoint accepts at the same quality.
/// Bundling LAME or shelling out to ffmpeg would add hundreds of KB of
/// binary or a user-installation prerequisite for zero behavioural
/// difference.
struct MediaConversionService: Sendable {

    /// Re-encode the audio in `inputURL` (mp3, m4a, wav, or mp4) into a
    /// freshly-written `.m4a` at `outputURL`. Any pre-existing file at
    /// `outputURL` is removed first so the export has a clean target;
    /// any partial output left behind by a failed export is also
    /// cleaned up before the typed error is rethrown.
    ///
    /// Throws:
    /// - `.noAudioTrack` if the asset has no audio track at all (an MP4
    ///   recorded with the mic muted, for example).
    /// - `.conversionFailed(reason)` for any AVFoundation error or
    ///   pre-flight failure.
    /// - `CancellationError` if the task was cancelled mid-export
    ///   (AVAssetExportSession reports `.cancelled`).
    func extractAudio(from inputURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: inputURL)

        // Pre-flight: the asset must contain at least one audio track.
        // A user dropping a video they shot with the mic muted would
        // otherwise silently produce a zero-byte M4A.
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ManualUploadError.conversionFailed(error.localizedDescription)
        }
        guard !audioTracks.isEmpty else {
            throw ManualUploadError.noAudioTrack
        }

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ManualUploadError.conversionFailed("AVAssetExportSession could not be created for this input.")
        }
        exporter.outputFileType = .m4a
        exporter.outputURL = outputURL

        let outputPath = outputURL.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: outputPath) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            try await runExport(exporter)
        } catch {
            // Wipe partial output so a retry doesn't trip over leftover
            // bytes (or, more subtly, so the next `uniqueURL` collision
            // counter starts from a clean state).
            try? FileManager.default.removeItem(at: outputURL)
            if error is CancellationError { throw error }
            if let typed = error as? ManualUploadError { throw typed }
            throw ManualUploadError.conversionFailed(error.localizedDescription)
        }
    }

    /// Bridge `AVAssetExportSession.exportAsynchronously` (callback-based,
    /// deprecated on macOS 15+ but the only path that supports macOS 14)
    /// into structured concurrency. The newer `export(to:as:)` async API
    /// is macOS-15-only and Jot targets macOS 14.
    private func runExport(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .failed:
                    let message = exporter.error?.localizedDescription
                        ?? "Export failed with no error details."
                    continuation.resume(throwing: ManualUploadError.conversionFailed(message))
                default:
                    continuation.resume(throwing: ManualUploadError.conversionFailed("Export ended in unexpected state: \(exporter.status.rawValue)."))
                }
            }
        }
    }
}
