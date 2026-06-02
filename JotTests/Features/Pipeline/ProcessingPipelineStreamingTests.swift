import Testing
import Foundation
@testable import Jot

/// Integration tests for v0.6.0 streaming transcription: parts that finalize
/// *during* a recording are transcribed immediately and the result reused at
/// assembly, so only the trailing part uploads after Stop.
///
/// These drive the real `FolderWatcher` + `MeetingBatchAccumulator` against a
/// tmpdir, with a `URLProtocol`-mocked transcription endpoint that counts
/// requests. The request count is the key signal: N parts must produce exactly
/// N transcription requests (each part once) — a count of 2N would mean the
/// streamed results weren't reused and every part was re-transcribed.
///
/// Serialized so the shared `MockURLProtocol` responder isn't clobbered.
@Suite(.serialized)
struct ProcessingPipelineStreamingTests {

    private static let baseURL = URL(string: "https://api.test/v1/audio/transcriptions")!

    /// Thread-safe request counter (the mocked endpoint is hit from URLSession's
    /// own queue, possibly while the test thread reads the count).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @MainActor
    final class Capture {
        var states: [PipelineState] = []
        var entries: [AuditLogEntry] = []
    }

    private static func makeFolders() throws -> (watch: URL, output: URL, ledger: ProcessedFilesLedger) {
        let watch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-stream-watch-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-stream-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-stream-ledger-\(UUID().uuidString).json")
        return (watch, output, ProcessedFilesLedger(url: ledgerURL))
    }

    @discardableResult
    private static func writeAudio(_ name: String, to folder: URL, bytes: Int = 2_048) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0xCD, count: bytes).write(to: url, options: [.atomic])
        return url
    }

    private static func okResponse(body text: String) -> (HTTPURLResponse, Data) {
        let r = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "application/json"])!
        let payload: [String: Any] = [
            "task": "transcribe", "language": "english", "duration": 1.0, "text": text,
            "segments": [["id": 0, "start": 0.0, "end": 1.0, "text": text]]
        ]
        return (r, try! JSONSerialization.data(withJSONObject: payload, options: []))
    }

    private static func errorResponse(status: Int) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
    }

    @MainActor
    private static func waitForCondition(
        timeout: TimeInterval = 8.0,
        pollInterval: TimeInterval = 0.05,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return predicate()
    }

    private static func snapshot(name: String) -> MeetingContextSnapshot {
        MeetingContextSnapshot(
            meetingName: name, organizationId: nil, organizationName: nil,
            meetingSpecificContext: nil, resolvedCompiledContext: "", lastEditedAt: Date()
        )
    }

    @MainActor
    private static func makePipeline(
        watch: URL, output: URL, ledger: ProcessedFilesLedger,
        accumulator: MeetingBatchAccumulator, capture: Capture
    ) async throws -> ProcessingPipeline {
        let watcher = try await FolderWatcher(
            folderURL: watch, stableDuration: 0.3, recheckInterval: 0.2, ledger: ledger
        )
        let config = PipelineConfig(
            watchFolder: watch, outputFolder: output,
            apiBaseURL: baseURL, model: "whisper-test", apiKey: "sk-test"
        )
        return ProcessingPipeline(
            config: config,
            watcher: watcher,
            transcriptionClient: TranscriptionClient(session: MockURLSession.make()),
            fileOrganizer: FileOrganizer(),
            onStateChange: { state in Task { @MainActor in capture.states.append(state) } },
            onAuditEntry: { entry in Task { @MainActor in capture.entries.append(entry) } },
            batchAccumulator: accumulator
        )
    }

    // MARK: - Reuse: streamed parts are not re-transcribed at assembly

    @Test
    @MainActor
    func partsStreamedDuringRecording_areReusedAtAssembly_notRetranscribed() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let counter = Counter()
        MockURLProtocol.responder = { _ in
            let n = counter.increment()
            return Self.okResponse(body: "part \(n)")
        }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let accumulator = MeetingBatchAccumulator(settleDelay: 1.5)
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            accumulator: accumulator, capture: capture
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        // Recording starts ~now, so freshly-written parts fall inside the window.
        await accumulator.noteRecordingStarted(snapshot: Self.snapshot(name: "Stream Meeting"),
                                               at: Date().addingTimeInterval(-1))

        // Part 1 finalizes mid-recording → streamed immediately.
        try Self.writeAudio("part-a.mp3", to: watch)
        #expect(await Self.waitForCondition { counter.count >= 1 }, "Part 1 should stream during recording")

        // Part 2 finalizes mid-recording → streamed immediately.
        try Self.writeAudio("part-b.mp3", to: watch)
        #expect(await Self.waitForCondition { counter.count >= 2 }, "Part 2 should stream during recording")

        // Stop. With both parts already streamed, assembly reuses them and
        // issues NO new transcription requests.
        await accumulator.noteRecordingStopped(at: Date())

        let succeeded = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(succeeded, "Batch should assemble to a success. Entries: \(capture.entries.map(\.message))")

        // The crux: exactly one request per part. 4 would mean re-transcription.
        #expect(counter.count == 2, "Streamed parts must be reused, not re-transcribed (got \(counter.count) requests)")

        // One meeting folder was produced.
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))) ?? []
        #expect(folders.contains { $0.hasSuffix(" - Stream Meeting") },
                "Expected a '… - Stream Meeting' folder, got \(folders)")
    }

    // MARK: - Fallback: a failed streamed part is re-transcribed at assembly

    @Test
    @MainActor
    func streamedPartThatFailed_isRetranscribedAtAssembly() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let counter = Counter()
        // First request (part 1's streamed attempt) fails with 500 — not
        // retried by the client. Everything after succeeds.
        MockURLProtocol.responder = { _ in
            let n = counter.increment()
            return n == 1 ? Self.errorResponse(status: 500) : Self.okResponse(body: "ok \(n)")
        }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let accumulator = MeetingBatchAccumulator(settleDelay: 1.5)
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            accumulator: accumulator, capture: capture
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        await accumulator.noteRecordingStarted(snapshot: Self.snapshot(name: "Fallback Meeting"),
                                               at: Date().addingTimeInterval(-1))

        // Part 1 streams and fails (request #1 → 500).
        try Self.writeAudio("part-a.mp3", to: watch)
        #expect(await Self.waitForCondition { counter.count >= 1 }, "Part 1 streamed attempt should fire")

        // Part 2 streams and succeeds (request #2).
        try Self.writeAudio("part-b.mp3", to: watch)
        #expect(await Self.waitForCondition { counter.count >= 2 }, "Part 2 should stream")

        await accumulator.noteRecordingStopped(at: Date())

        // Assembly: part 1's streamed task threw → re-transcribed fresh
        // (request #3, succeeds); part 2 reused. Meeting still completes.
        let succeeded = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(succeeded, "A failed streamed part must fall back to a fresh transcription. Entries: \(capture.entries.map(\.message))")
        #expect(counter.count == 3, "Part 1 should be transcribed twice (failed stream + assembly retry); got \(counter.count)")
    }
}
