import Testing
import Foundation
import AVFoundation
@testable import Jot

/// Integration tests for `AudioChunker` against its real boundary: a
/// generated `.m4a` on disk split through `AVAssetExportSession`. We
/// synthesize a short silent recording, then drive the size thresholds off
/// the actual file size so the test is deterministic regardless of how the
/// AAC encoder happens to compress silence.
struct AudioChunkerIntegrationTests {

    // MARK: - Helpers

    /// Write `seconds` of silence to a fresh `.m4a` (AAC) at `url`.
    private func writeSilentM4A(seconds: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let pcmFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(pcmFormat.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "test", code: 1)
        }
        buffer.frameLength = frameCount // zero-filled => silence
        try file.write(from: buffer)
    }

    private func fileSize(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    private func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunker-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Tests

    @Test
    func test_chunkIfNeeded_underLimit_returnsNil() async throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.m4a")
        try writeSilentM4A(seconds: 3, to: source)

        let size = try fileSize(source)
        // maxBytes well above the file: no split expected.
        let result = try await AudioChunker().chunkIfNeeded(
            source,
            maxBytes: size * 4,
            targetBytes: size * 2
        )
        #expect(result == nil)
    }

    @Test
    func test_chunkIfNeeded_overLimit_producesMultipleValidChunks() async throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.m4a")
        try writeSilentM4A(seconds: 6, to: source)

        let size = try fileSize(source)
        let total = try await duration(source)

        // Force a multi-way split: file > maxBytes, target ~a third of the
        // file so it lands in 3–4 chunks (integer division of the target
        // makes the exact count encoder-dependent — the contract is "more
        // than one chunk that reconstructs the timeline", not an exact N).
        let chunkSet = try await AudioChunker().chunkIfNeeded(
            source,
            maxBytes: size / 2,
            targetBytes: size / 3
        )

        let set = try #require(chunkSet)
        defer { try? FileManager.default.removeItem(at: set.directory) }

        #expect(set.urls.count >= 2)

        // Every chunk is a real, non-empty audio file.
        var summedDuration = 0.0
        for url in set.urls {
            #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
            let d = try await duration(url)
            #expect(d > 0)
            summedDuration += d
        }

        // The chunks reconstruct the original timeline. AAC encoder
        // priming/padding shifts each boundary by a few milliseconds, so we
        // allow a loose tolerance rather than demanding an exact sum.
        #expect(abs(summedDuration - total) < 1.0)
    }

    @Test
    func test_chunkIfNeeded_directoryIsRemovable_forCleanup() async throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.m4a")
        try writeSilentM4A(seconds: 5, to: source)

        let size = try fileSize(source)
        let chunkSet = try await AudioChunker().chunkIfNeeded(
            source,
            maxBytes: size / 2,
            targetBytes: size / 2
        )
        let set = try #require(chunkSet)

        #expect(FileManager.default.fileExists(atPath: set.directory.path(percentEncoded: false)))
        // The pipeline's `defer` removes the whole directory in one call.
        try FileManager.default.removeItem(at: set.directory)
        #expect(!FileManager.default.fileExists(atPath: set.directory.path(percentEncoded: false)))
    }
}
