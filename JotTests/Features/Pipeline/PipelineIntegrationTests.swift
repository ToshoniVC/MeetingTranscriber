import Testing
import Foundation
@testable import Jot

/// End-to-end integration tests for `ProcessingPipeline`. These exercise
/// the real `FolderWatcher` (against a real tmpdir), real `FileOrganizer`,
/// and a `URLProtocol`-mocked `TranscriptionClient`.
///
/// Serialized so the shared `MockURLProtocol` responder isn't clobbered
/// across parallel cases.
@Suite(.serialized)
struct PipelineIntegrationTests {

    // MARK: - Fixtures

    private static let baseURL = URL(string: "https://api.test/v1/audio/transcriptions")!

    private static func makeFolders() throws -> (watch: URL, output: URL, ledger: ProcessedFilesLedger) {
        let watch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-pipe-watch-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-pipe-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-pipe-ledger-\(UUID().uuidString).json")
        return (watch, output, ProcessedFilesLedger(url: ledgerURL))
    }

    private static func writeAudio(_ name: String, to folder: URL, bytes: Int = 2_048) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0xCD, count: bytes).write(to: url, options: [.atomic])
        return url
    }

    private static func okResponse(body: String) -> (HTTPURLResponse, Data) {
        let r = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (r, Data(body.utf8))
    }

    private static func errorResponse(status: Int) -> (HTTPURLResponse, Data) {
        let r = HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (r, Data())
    }

    /// Wait up to `timeout` seconds for `predicate` to become true.
    /// Returns true if condition was met, false on timeout.
    @MainActor
    private static func waitForCondition(
        timeout: TimeInterval = 6.0,
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

    /// Box for capturing state/entries from the pipeline's sendable closures.
    @MainActor
    final class Capture {
        var states: [PipelineState] = []
        var entries: [AuditLogEntry] = []
    }

    @MainActor
    private static func makePipeline(
        watch: URL, output: URL, ledger: ProcessedFilesLedger,
        session: URLSession,
        capture: Capture
    ) async throws -> ProcessingPipeline {
        let watcher = try await FolderWatcher(
            folderURL: watch,
            stableDuration: 0.3,
            recheckInterval: 0.2,
            ledger: ledger
        )
        let config = PipelineConfig(
            watchFolder: watch,
            outputFolder: output,
            apiBaseURL: baseURL,
            model: "whisper-test",
            apiKey: "sk-test"
        )
        return ProcessingPipeline(
            config: config,
            watcher: watcher,
            transcriptionClient: TranscriptionClient(session: session),
            fileOrganizer: FileOrganizer(),
            onStateChange: { state in
                Task { @MainActor in capture.states.append(state) }
            },
            onAuditEntry: { entry in
                Task { @MainActor in capture.entries.append(entry) }
            }
        )
    }

    // MARK: - Happy path

    @Test
    @MainActor
    func droppedFile_endsAsMeetingFolderWithTranscript() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed content") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("alpha.mp3", to: watch)

        // Wait for a success entry to appear.
        let got = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(got, "Expected a success audit entry within timeout. Entries: \(capture.entries.map(\.message))")

        // Meeting folder exists with transcript + moved audio.
        let meeting = output.appendingPathComponent("alpha", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: meeting.path(percentEncoded: false)))
        let transcriptText = try String(
            contentsOf: meeting.appendingPathComponent("alpha.txt"),
            encoding: .utf8
        )
        #expect(transcriptText == "transcribed content")
        #expect(FileManager.default.fileExists(
            atPath: meeting.appendingPathComponent("alpha.mp3").path(percentEncoded: false)
        ))

        // Watch folder is empty (audio was moved, not copied).
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: watch.path(percentEncoded: false))
        #expect(leftovers.isEmpty)

        // Final state should be `.idle` after the run completes.
        let returnedToIdle = await Self.waitForCondition {
            if case .idle = capture.states.last { return true }
            return false
        }
        #expect(returnedToIdle)
    }

    // MARK: - Failure path

    @Test
    @MainActor
    func transcriptionAuthFailure_recordsRetryableEntry_andLeavesFileInWatchFolder() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.errorResponse(status: 401) }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        let audio = try Self.writeAudio("bravo.mp3", to: watch)

        // Wait for a failure entry.
        let got = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .failure && $0.retryable }
        }
        #expect(got, "Expected a retryable failure entry. Entries: \(capture.entries.map(\.message))")

        // PRD §4.3: failed files must stay in the Watch Folder.
        #expect(FileManager.default.fileExists(atPath: audio.path(percentEncoded: false)))

        // No meeting folder was created.
        let meeting = output.appendingPathComponent("bravo", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: meeting.path(percentEncoded: false)))
    }

    // MARK: - Re-drop after success

    @Test
    @MainActor
    func sameFilenameDroppedAgainAfterSuccess_isProcessedAgain() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        var counter = 0
        MockURLProtocol.responder = { _ in
            counter += 1
            return Self.okResponse(body: "run \(counter)")
        }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        // First drop.
        _ = try Self.writeAudio("delta.mp3", to: watch)
        let firstDone = await Self.waitForCondition {
            capture.entries.filter { $0.kind == .success }.count == 1
        }
        #expect(firstDone, "First run should succeed. Entries: \(capture.entries.map(\.message))")

        // Same filename, dropped a second time at the same Watch Folder path.
        // After Phase 5 (this fix), the ledger no longer blocks this.
        _ = try Self.writeAudio("delta.mp3", to: watch)
        let secondDone = await Self.waitForCondition {
            capture.entries.filter { $0.kind == .success }.count == 2
        }
        #expect(secondDone, "Second drop with same path should also succeed. Entries: \(capture.entries.map(\.message))")

        // Two meeting folders: `delta` and `delta-2`.
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("delta").path(percentEncoded: false)
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("delta-2").path(percentEncoded: false)
        ))
    }

    // MARK: - Retry path

    @Test
    @MainActor
    func retry_afterTransientFailure_succeeds() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        // First request 500, then 200 on subsequent calls.
        // (The transcription client retries once on transientNetwork/timeout
        // but not on 5xx — so the first run produces a failure entry, and
        // the user-triggered retry succeeds.)
        var requestNumber = 0
        MockURLProtocol.responder = { _ in
            requestNumber += 1
            return requestNumber == 1
                ? Self.errorResponse(status: 500)
                : Self.okResponse(body: "second attempt worked")
        }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        let audio = try Self.writeAudio("charlie.mp3", to: watch)

        // Wait for the first failure entry.
        let gotFailure = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .failure }
        }
        #expect(gotFailure, "First run should fail. Entries: \(capture.entries.map(\.message))")
        // File still there.
        #expect(FileManager.default.fileExists(atPath: audio.path(percentEncoded: false)))

        // User clicks Retry.
        await pipeline.retry(url: audio)

        // Wait for the success entry.
        let gotSuccess = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(gotSuccess, "Retry should produce a success. Entries: \(capture.entries.map(\.message))")

        // Meeting folder + transcript now exists.
        let meeting = output.appendingPathComponent("charlie", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: meeting.path(percentEncoded: false)))
        let transcript = try String(
            contentsOf: meeting.appendingPathComponent("charlie.txt"),
            encoding: .utf8
        )
        #expect(transcript == "second attempt worked")
    }
}
