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

    /// Find a single output-folder name ending with `suffix`. Returns nil
    /// if no folder matches; used by the rename tests where the leading
    /// timestamp prefix is non-deterministic (depends on the file's
    /// creation time) but the meeting-name tail is fixed.
    private static func findOutputFolder(under output: URL, endingWith suffix: String) throws -> String? {
        let entries = try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))
        return entries.first { $0.hasSuffix(suffix) }
    }

    /// Wrap `body` as a `verbose_json` transcription response — the format
    /// `TranscriptionClient` decodes since v0.4.2. Pipeline-level
    /// integration tests don't care about the diagnostic fields; they only
    /// need the `text` to round-trip.
    private static func okResponse(body text: String) -> (HTTPURLResponse, Data) {
        let r = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "application/json"])!
        let payload: [String: Any] = [
            "task": "transcribe",
            "language": "english",
            "duration": 1.0,
            "text": text,
            "segments": [["id": 0, "start": 0.0, "end": 1.0, "text": text]]
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload, options: [])
        return (r, body)
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
        capture: Capture,
        meetingContextStore: MeetingContextStore? = nil
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
        let consume: (@Sendable (Date) async -> MeetingContextSnapshot?)?
        if let store = meetingContextStore {
            consume = { creationDate in
                await MainActor.run { store.consume(forFileCreatedAt: creationDate) }
            }
        } else {
            consume = nil
        }
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
            },
            consumeMeetingContext: consume
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

    // MARK: - Meeting-name rename

    /// File creation date is inside Jot's recording window → file gets
    /// renamed to the meeting name before transcription, and the meeting
    /// folder + transcript inherit that name.
    @Test
    @MainActor
    func droppedFile_inRecordingWindow_isRenamedToMeetingName() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "the standup notes") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let store = MeetingContextStore()
        // Open an active recording window centered on "now" — the file we'll
        // drop has a fresh creation date, so it must land inside the window.
        store.recordStarted(meetingName: "Standup", at: Date().addingTimeInterval(-1))
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            meetingContextStore: store
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("2026-05-28_14-24-00.mp3", to: watch)

        let got = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(got, "Expected a success audit entry. Entries: \(capture.entries.map(\.message))")

        // Meeting folder + transcript named after the meeting, prefixed
        // with the recording-start timestamp for chronological sort order
        // in Finder.
        let folderName = try #require(
            try Self.findOutputFolder(under: output, endingWith: " - Standup"),
            "Expected an output folder ending with ' - Standup'"
        )
        let meeting = output.appendingPathComponent(folderName, isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: meeting.appendingPathComponent("\(folderName).mp3").path(percentEncoded: false)
        ))
        let transcript = try String(
            contentsOf: meeting.appendingPathComponent("\(folderName).txt"),
            encoding: .utf8
        )
        #expect(transcript == "the standup notes")
        // Folder name has the documented prefix shape.
        #expect(folderName.range(of: #"^\d{4}\.\d{2}\.\d{2} - \d{2}\.\d{2} - Standup$"#, options: .regularExpression) != nil)

        // The pending entry was consumed.
        #expect(store.pending == nil)

        // An audit "Renamed …" info row was emitted.
        #expect(capture.entries.contains { $0.kind == .info && $0.message.contains("Renamed") && $0.message.contains("meeting name") })
    }

    /// File creation date is BEFORE the recording window → no rename. The
    /// file flows through with its AH-stamped name. This is the protection
    /// against renaming files the user produced through AH directly.
    @Test
    @MainActor
    func droppedFile_beforeRecordingWindow_keepsOriginalName() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "manual ah recording") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let store = MeetingContextStore()
        // Start a recording window in the FUTURE so the file we're about to
        // drop (created ~now) is definitively before the window.
        store.recordStarted(meetingName: "Standup", at: Date().addingTimeInterval(3600))
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            meetingContextStore: store
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("2026-05-28_10-00-00.mp3", to: watch)

        let got = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(got)

        // Original AH-style name preserved.
        let meeting = output.appendingPathComponent("2026-05-28_10-00-00", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: meeting.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(
            atPath: meeting.appendingPathComponent("2026-05-28_10-00-00.mp3").path(percentEncoded: false)
        ))

        // The future-dated pending was NOT consumed — it's preserved for
        // when the actual file from that session arrives later.
        #expect(store.pending != nil)

        // No rename audit row emitted.
        #expect(!capture.entries.contains { $0.message.contains("Renamed") })
    }

    /// File creation date is AFTER the recorded stop time by more than the
    /// slop → no rename. Covers the "user used AH manually after a Jot
    /// session ended" scenario.
    @Test
    @MainActor
    func droppedFile_afterRecordingStopped_keepsOriginalName() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "later manual recording") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let store = MeetingContextStore()
        // Recording that ran 10s in the past, lasted 1s — file dropped now
        // is well after the stop+slop boundary.
        let pastStart = Date().addingTimeInterval(-10)
        store.recordStarted(meetingName: "EarlierMeeting", at: pastStart)
        store.recordStopped(at: pastStart.addingTimeInterval(1))
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            meetingContextStore: store
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("2026-05-28_14-30-00.mp3", to: watch)

        let got = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(got)

        let meeting = output.appendingPathComponent("2026-05-28_14-30-00", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: meeting.path(percentEncoded: false)))
        #expect(!capture.entries.contains { $0.message.contains("Renamed") })
    }

    /// Meeting name contains forbidden characters → sanitization kicks in,
    /// rename succeeds with a cleaned-up name.
    @Test
    @MainActor
    func meetingName_withForbiddenChars_isSanitizedBeforeRename() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "client call notes") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let store = MeetingContextStore()
        store.recordStarted(meetingName: "Client/Project:Q3", at: Date().addingTimeInterval(-1))
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            meetingContextStore: store
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("2026-05-28_15-00-00.mp3", to: watch)

        let got = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(got)

        // Both `/` and `:` became `-`, then the consecutive hyphens collapsed.
        // The timestamp prefix sits ahead of the sanitized name.
        let folderName = try #require(
            try Self.findOutputFolder(under: output, endingWith: " - Client-Project-Q3"),
            "Expected an output folder ending with ' - Client-Project-Q3'"
        )
        let meeting = output.appendingPathComponent(folderName, isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: meeting.appendingPathComponent("\(folderName).mp3").path(percentEncoded: false)
        ))
    }

    /// No `MeetingContextStore` injected → the pipeline behaves exactly as
    /// it did before this feature. (Belt-and-braces — confirms the rename
    /// path is gated entirely on the consume closure being present.)
    @Test
    @MainActor
    func noMeetingContextStore_pipelineKeepsOriginalName() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "no store wired") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            meetingContextStore: nil
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("untouched.mp3", to: watch)

        let got = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(got)

        let meeting = output.appendingPathComponent("untouched", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: meeting.path(percentEncoded: false)))
    }
}
