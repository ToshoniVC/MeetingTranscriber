import Testing
import Foundation
@testable import Jot

/// Tests for batch-aware, idempotent retry (v0.7.1).
///
/// Before this fix, clicking Retry on a failed multi-part (Audio Hijack
/// split) recording re-ran only the *first* part as a lone single-file
/// meeting — stranding the rest and losing the meeting name. These tests
/// pin the corrected behavior: a batch failure carries its full part list +
/// name/context on the audit entry, so Retry replays the whole meeting as
/// one unit, retires the original failure row, and fails fast (without
/// fragmenting) when a part has gone missing.
///
/// Serialized so the shared `MockURLProtocol` responder isn't clobbered.
@Suite(.serialized)
struct ProcessingPipelineRetryTests {

    private static let baseURL = URL(string: "https://api.test/v1/audio/transcriptions")!

    /// Flips the mocked endpoint from failing (original run) to succeeding
    /// (the retry) mid-test. Thread-safe — URLSession hits it off the test thread.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var _ok = false
        var ok: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _ok }
            set { lock.lock(); _ok = newValue; lock.unlock() }
        }
    }

    @MainActor
    final class Capture {
        var states: [PipelineState] = []
        var entries: [AuditLogEntry] = []
        var retiredIds: [UUID] = []
    }

    private static func makeFolders() throws -> (watch: URL, output: URL, ledger: ProcessedFilesLedger) {
        let watch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-retry-watch-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-retry-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-retry-ledger-\(UUID().uuidString).json")
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
            onRetrySucceeded: { id in Task { @MainActor in capture.retiredIds.append(id) } },
            batchAccumulator: accumulator
        )
    }

    // MARK: - reconstructBatch (pure)

    @Test
    func reconstructBatch_fromBatchFailureEntry_rebuildsPartsAndSnapshot() {
        let entry = AuditLogEntry(
            kind: .failure,
            sourcePath: "/tmp/p1.mp3",
            message: "fail",
            retryable: true,
            organizationName: "Acme",
            batchPartPaths: ["/tmp/p1.mp3", "/tmp/p2.mp3", "/tmp/p3.mp3"],
            retryMeetingName: "Board Meeting",
            retryCompiledContext: "Org: Acme",
            recordingStartedAt: Date(timeIntervalSince1970: 1_000)
        )
        let batch = try! #require(ProcessingPipeline.reconstructBatch(from: entry))
        #expect(batch.parts.map(\.lastPathComponent) == ["p1.mp3", "p2.mp3", "p3.mp3"])
        #expect(batch.snapshot.meetingName == "Board Meeting")
        #expect(batch.snapshot.organizationName == "Acme")
        #expect(batch.snapshot.resolvedCompiledContext == "Org: Acme")
        #expect(batch.startedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test
    func reconstructBatch_fromSingleFileFailure_isNil() {
        let entry = AuditLogEntry(
            kind: .failure, sourcePath: "/tmp/solo.mp3", message: "fail", retryable: true
        )
        #expect(ProcessingPipeline.reconstructBatch(from: entry) == nil)
    }

    // MARK: - Integration: batch retry replays the whole meeting

    @Test
    @MainActor
    func retryingFailedBatch_replaysWholeMeeting_andRetiresOriginalEntry() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let gate = Gate()
        MockURLProtocol.responder = { _ in
            gate.ok ? Self.okResponse(body: "part text") : Self.errorResponse(status: 500)
        }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let accumulator = MeetingBatchAccumulator(settleDelay: 1.0)
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            accumulator: accumulator, capture: capture
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        // Record a two-part meeting while the endpoint is failing.
        await accumulator.noteRecordingStarted(
            snapshot: Self.snapshot(name: "Retry Meeting"),
            at: Date().addingTimeInterval(-1)
        )
        try Self.writeAudio("part-a.mp3", to: watch)
        try Self.writeAudio("part-b.mp3", to: watch)
        await accumulator.noteRecordingStopped(at: Date())

        // The batch fails and records ONE failure entry carrying both parts.
        let gotFailure = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .failure && ($0.batchPartPaths?.count ?? 0) == 2 }
        }
        #expect(gotFailure, "Expected a batch failure carrying 2 part paths. Entries: \(capture.entries.map(\.message))")
        let failureEntry = try #require(capture.entries.first { $0.kind == .failure && $0.batchPartPaths != nil })
        #expect(failureEntry.retryMeetingName == "Retry Meeting")
        // Both parts still in the Watch Folder (failure never moves files).
        #expect(FileManager.default.fileExists(atPath: watch.appendingPathComponent("part-a.mp3").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: watch.appendingPathComponent("part-b.mp3").path(percentEncoded: false)))

        // Provider recovers; user clicks Retry on the failure row.
        gate.ok = true
        await pipeline.retry(entry: failureEntry)

        // Exactly one combined success — not two lone single-file meetings.
        let gotSuccess = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(gotSuccess, "Retry should produce a combined success. Entries: \(capture.entries.map(\.message))")
        #expect(capture.entries.filter { $0.kind == .success }.count == 1,
                "A batch retry must produce one meeting, not one per part.")

        // One meeting folder named after the meeting, holding both parts.
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))) ?? []
        let meetingFolders = folders.filter { $0.hasSuffix(" - Retry Meeting") }
        #expect(meetingFolders.count == 1, "Expected one '… - Retry Meeting' folder, got \(folders)")
        let meeting = output.appendingPathComponent(meetingFolders[0], isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(atPath: meeting.path(percentEncoded: false))
        #expect(contents.filter { $0.hasSuffix(".mp3") }.count == 2, "Both parts should be filed together, got \(contents)")

        // Watch Folder is empty again — both parts were moved out.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: watch.path(percentEncoded: false))
        #expect(leftovers.filter { $0.hasSuffix(".mp3") }.isEmpty, "Watch folder should be clear, got \(leftovers)")

        // The original failure row was retired (Retry button disappears).
        #expect(capture.retiredIds.contains(failureEntry.id),
                "A successful retry must retire the original failure entry.")
    }

    // MARK: - Idempotency: a missing part fails fast without fragmenting

    @Test
    @MainActor
    func retryingBatch_withMissingPart_failsClearly_withoutCreatingMeeting() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        // Endpoint would succeed — but we must never reach it; the missing
        // part has to short-circuit before any transcription.
        MockURLProtocol.responder = { _ in Self.okResponse(body: "should not be used") }

        let (watch, output, ledger) = try Self.makeFolders()
        // Parts live OUTSIDE the watch folder so the live watcher doesn't
        // pick the survivor up as its own single-file meeting.
        let partsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-retry-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: partsDir)
        }
        let capture = Capture()
        let accumulator = MeetingBatchAccumulator(settleDelay: 1.0)
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            accumulator: accumulator, capture: capture
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        // One part survives on disk; the other is gone (already filed by a
        // pre-fix single-file retry, in the real-world scenario).
        let survivor = try Self.writeAudio("part-a.mp3", to: partsDir)
        let ghost = partsDir.appendingPathComponent("part-b.mp3")

        let entry = AuditLogEntry(
            kind: .failure,
            sourcePath: survivor.path(percentEncoded: false),
            message: "All providers failed",
            retryable: true,
            batchPartPaths: [survivor.path(percentEncoded: false), ghost.path(percentEncoded: false)],
            retryMeetingName: "Ghost Meeting",
            // Anchor far in the past so relocation can't match the survivor.
            recordingStartedAt: Date(timeIntervalSince1970: 0)
        )

        await pipeline.retry(entry: entry)

        // A clear failure mentioning the missing part — not a partial meeting.
        let gotMissingFailure = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .failure && $0.message.localizedCaseInsensitiveContains("missing") }
        }
        #expect(gotMissingFailure, "Expected a 'missing part' failure. Entries: \(capture.entries.map(\.message))")

        // No success, no meeting folder, and the original entry is NOT retired.
        #expect(!capture.entries.contains { $0.kind == .success })
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))) ?? []
        #expect(folders.filter { $0.hasSuffix(" - Ghost Meeting") }.isEmpty, "No meeting should be created, got \(folders)")
        #expect(!capture.retiredIds.contains(entry.id), "A failed retry must not retire the entry.")

        // The survivor is untouched on disk.
        #expect(FileManager.default.fileExists(atPath: survivor.path(percentEncoded: false)))
    }
}
