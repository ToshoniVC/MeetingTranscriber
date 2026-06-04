import Foundation
@preconcurrency import AVFoundation

/// Splits an audio file that would exceed the transcription endpoint's
/// upload-size limit into a series of smaller `.m4a` chunks, each sized to
/// fit comfortably under the limit. The pipeline transcribes every chunk
/// independently and stitches the results with
/// `TranscriptionResult.merging(_:)` — the same machinery that joins Audio
/// Hijack's split live recordings — so a multi-hour upload lands as one
/// continuous transcript instead of failing the provider's HTTP 413.
///
/// Splitting is by *time range*, sized from the file's average bytes-per-
/// second, exported through the same `AVAssetExportSession` + AppleM4A
/// (AAC) path `MediaConversionService` uses. No external binary, no new
/// dependency, and the produced `.m4a` is accepted by every endpoint.
struct AudioChunker: Sendable {

    enum ChunkingError: Error, Equatable {
        /// The asset reported a non-positive / unavailable duration, so we
        /// can't compute time ranges to split on. The caller falls back to
        /// a single upload.
        case indeterminateDuration
        /// The asset has no audio track at all (e.g. a muted video).
        case noAudioTrack
        /// An AVFoundation export failed for one of the chunks.
        case exportFailed(String)
    }

    /// A produced set of chunk files plus the temp directory that holds
    /// them. The caller must remove `directory` once every chunk has been
    /// transcribed — a `defer` at the call site does this in one step,
    /// regardless of chunk count.
    struct ChunkSet: Sendable, Equatable {
        let urls: [URL]
        let directory: URL
    }

    /// Split `url` only when its byte size exceeds `maxBytes`. Returns
    /// `nil` when the file is already within the limit — the caller
    /// transcribes the original unchanged, preserving pre-chunking
    /// behaviour. Otherwise re-encodes the audio into contiguous `.m4a`
    /// chunks each targeting `targetBytes`, returned in chronological
    /// order.
    ///
    /// Throws `ChunkingError` when the file is oversized but unsplittable
    /// (no audio track, indeterminate duration, or a failed export); the
    /// pipeline treats that as "couldn't split" and falls back to a single
    /// upload so the endpoint's own error still surfaces.
    func chunkIfNeeded(
        _ url: URL,
        maxBytes: Int,
        targetBytes: Int
    ) async throws -> ChunkSet? {
        let fileBytes = try fileSize(of: url)
        guard fileBytes > maxBytes else { return nil }

        let asset = AVURLAsset(url: url)

        // We need both an audio track and a real duration to split on.
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ChunkingError.exportFailed(error.localizedDescription)
        }
        guard !audioTracks.isEmpty else { throw ChunkingError.noAudioTrack }

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw ChunkingError.indeterminateDuration
        }
        let totalSeconds = duration.seconds
        guard duration.isValid, !duration.isIndefinite, totalSeconds > 0 else {
            throw ChunkingError.indeterminateDuration
        }

        let slices = Self.chunkRanges(
            fileBytes: fileBytes,
            durationSeconds: totalSeconds,
            targetBytes: targetBytes
        )

        // Stage chunks in a dedicated temp directory so cleanup is a single
        // directory removal regardless of how many chunks we produced.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var urls: [URL] = []
        urls.reserveCapacity(slices.count)
        do {
            for (index, slice) in slices.enumerated() {
                let chunkURL = directory.appendingPathComponent(
                    String(format: "chunk-%03d.m4a", index)
                )
                try await export(
                    asset: asset,
                    startSeconds: slice.start,
                    durationSeconds: slice.duration,
                    to: chunkURL
                )
                urls.append(chunkURL)
            }
        } catch {
            // Leave no half-written chunk directory behind on failure.
            try? FileManager.default.removeItem(at: directory)
            if error is CancellationError { throw error }
            if let typed = error as? ChunkingError { throw typed }
            throw ChunkingError.exportFailed(error.localizedDescription)
        }

        return ChunkSet(urls: urls, directory: directory)
    }

    // MARK: - Pure planning

    /// A contiguous slice of the source timeline, in seconds.
    struct TimeSlice: Equatable, Sendable {
        let start: Double
        let duration: Double
    }

    /// Compute evenly-sized contiguous time ranges that each land near
    /// `targetBytes`, given the file's overall byte size and duration. The
    /// chunk count is `ceil(fileBytes / targetBytes)` (at least 2 — we only
    /// ever chunk a file that's already over the limit); dividing the
    /// *duration* evenly across that count keeps the chunks uniform, while
    /// the file's average bytes-per-second keeps each one near the target
    /// size. Pure and deterministic so it's unit-testable without
    /// AVFoundation.
    static func chunkRanges(
        fileBytes: Int,
        durationSeconds: Double,
        targetBytes: Int
    ) -> [TimeSlice] {
        guard durationSeconds > 0, targetBytes > 0, fileBytes > 0 else {
            return [TimeSlice(start: 0, duration: max(0, durationSeconds))]
        }
        let rawCount = Int((Double(fileBytes) / Double(targetBytes)).rounded(.up))
        let count = max(2, rawCount)
        let sliceDuration = durationSeconds / Double(count)
        var slices: [TimeSlice] = []
        slices.reserveCapacity(count)
        for i in 0..<count {
            let start = Double(i) * sliceDuration
            // The last slice runs to the exact end so floating-point drift
            // never leaves a sub-second sliver untranscribed.
            let dur = (i == count - 1) ? (durationSeconds - start) : sliceDuration
            slices.append(TimeSlice(start: start, duration: dur))
        }
        return slices
    }

    // MARK: - Private

    private func fileSize(of url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    /// Export one time range of `asset` to a fresh `.m4a`. Mirrors
    /// `MediaConversionService.runExport` — the deprecated callback API is
    /// the only export path that supports macOS 14 (Jot's floor); the
    /// async `export(to:as:)` is macOS-15-only.
    private func export(
        asset: AVURLAsset,
        startSeconds: Double,
        durationSeconds: Double,
        to outputURL: URL
    ) async throws {
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ChunkingError.exportFailed("AVAssetExportSession could not be created.")
        }
        exporter.outputFileType = .m4a
        exporter.outputURL = outputURL
        let timescale: CMTimeScale = 600
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: timescale),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: timescale)
        )

        if FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: outputURL)
        }

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
                    continuation.resume(throwing: ChunkingError.exportFailed(message))
                default:
                    continuation.resume(throwing: ChunkingError.exportFailed("Export ended in unexpected state: \(exporter.status.rawValue)."))
                }
            }
        }
    }
}
