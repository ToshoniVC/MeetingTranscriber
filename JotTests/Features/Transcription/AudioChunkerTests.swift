import Testing
import Foundation
@testable import Jot

/// Unit tests for `AudioChunker.chunkRanges` — the pure time-range planner.
/// The AVFoundation export path is exercised separately in
/// `AudioChunkerIntegrationTests`.
struct AudioChunkerTests {

    private let epsilon = 1e-6

    @Test
    func test_chunkRanges_count_isCeilOfBytesOverTarget() {
        // 100 MiB at 15 MiB/chunk → ceil(100/15) = 7 chunks.
        let slices = AudioChunker.chunkRanges(
            fileBytes: 100 * 1024 * 1024,
            durationSeconds: 9000,
            targetBytes: 15 * 1024 * 1024
        )
        #expect(slices.count == 7)
    }

    @Test
    func test_chunkRanges_slicesAreContiguous() {
        let slices = AudioChunker.chunkRanges(
            fileBytes: 100 * 1024 * 1024,
            durationSeconds: 9000,
            targetBytes: 15 * 1024 * 1024
        )
        #expect(slices.first?.start == 0)
        for i in 1..<slices.count {
            let prev = slices[i - 1]
            let cur = slices[i]
            #expect(abs((prev.start + prev.duration) - cur.start) < epsilon)
        }
    }

    @Test
    func test_chunkRanges_coversFullDurationExactly() {
        let total = 9000.0
        let slices = AudioChunker.chunkRanges(
            fileBytes: 100 * 1024 * 1024,
            durationSeconds: total,
            targetBytes: 15 * 1024 * 1024
        )
        let last = slices.last!
        #expect(abs((last.start + last.duration) - total) < epsilon)
        let sum = slices.reduce(0) { $0 + $1.duration }
        #expect(abs(sum - total) < epsilon)
    }

    @Test
    func test_chunkRanges_neverFewerThanTwoChunks() {
        // File only marginally over a single chunk's target still splits in
        // two — we only reach here when the file is over the upload limit.
        let slices = AudioChunker.chunkRanges(
            fileBytes: 16 * 1024 * 1024,
            durationSeconds: 600,
            targetBytes: 15 * 1024 * 1024
        )
        #expect(slices.count == 2)
        #expect(abs(slices[0].duration - 300) < epsilon)
        #expect(abs(slices[1].duration - 300) < epsilon)
    }

    @Test
    func test_chunkRanges_lastSliceAbsorbsRoundingRemainder() {
        // 7 chunks across 100s won't divide evenly; the final slice must run
        // to the exact end rather than leaving a sliver.
        let total = 100.0
        let slices = AudioChunker.chunkRanges(
            fileBytes: 100 * 1024 * 1024,
            durationSeconds: total,
            targetBytes: 15 * 1024 * 1024
        )
        #expect(slices.count == 7)
        #expect(abs((slices.last!.start + slices.last!.duration) - total) < epsilon)
    }

    @Test
    func test_chunkRanges_zeroDuration_returnsSingleDegenerateSlice() {
        // Defensive: a non-positive duration can't be split. The caller
        // guards against this upstream (throws indeterminateDuration), but
        // the pure function degrades gracefully rather than dividing by zero.
        let slices = AudioChunker.chunkRanges(
            fileBytes: 50 * 1024 * 1024,
            durationSeconds: 0,
            targetBytes: 15 * 1024 * 1024
        )
        #expect(slices.count == 1)
        #expect(slices[0].duration == 0)
    }
}
