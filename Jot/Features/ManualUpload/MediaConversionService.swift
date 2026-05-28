import Foundation
@preconcurrency import AVFoundation

/// Extracts the audio track from a `.mp4` and writes it to a `.m4a` file
/// at a caller-supplied destination. Uses `AVAssetExportSession` with the
/// `AppleM4A` preset — native, no external binary dependency. The
/// `FolderWatcher` already accepts `.m4a` (see `SupportedAudioType`), so
/// the resulting file flows through the existing pipeline unchanged.
///
/// The PRD spec calls this conversion "to `.mp3`", but AVFoundation has
/// no native MP3 encoder. Transcription endpoints (Whisper, Groq) don't
/// care about the container suffix — they accept M4A/AAC at the same
/// quality. Bundling an MP3 encoder (LAME) or shelling out to ffmpeg
/// would add hundreds of KB of binary or a user-installation
/// prerequisite for zero behavioural difference, so we use the native
/// path.
struct MediaConversionService: Sendable {

    /// Extract the audio track from `inputURL` (.mp4) into a freshly-
    /// written `.m4a` at `outputURL`. Any pre-existing file at
    /// `outputURL` is removed first so the export has a clean target;
    /// any partial output left behind by a failed export is also
    /// cleaned up before the typed error is rethrown.
    ///
    /// Throws:
    /// - `.noAudioTrack` if the asset has no audio track at all.
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
