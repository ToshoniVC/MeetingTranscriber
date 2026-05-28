import Testing
import Foundation
@testable import Jot

/// Pipeline tests that focus on the Notion post-success hook (Phase D).
/// Use the real `FolderWatcher` + `FileOrganizer`, a `URLProtocol`-mocked
/// transcription endpoint, and a `FakeNotionMeetingWriter` for the
/// post-success write so we can assert it was called with the exact
/// `(meetingName, transcript, additionalContext)` we expect.
@Suite(.serialized)
struct ProcessingPipelineNotionTests {

    private static let baseURL = URL(string: "https://api.test/v1/audio/transcriptions")!
    private static let notionConfig = NotionConfig(
        token: "secret_test",
        databaseId: "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
    )

    private static func makeFolders() throws -> (watch: URL, output: URL, ledger: ProcessedFilesLedger) {
        let watch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-pn-watch-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-pn-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-pn-ledger-\(UUID().uuidString).json")
        return (watch, output, ProcessedFilesLedger(url: ledgerURL))
    }

    private static func writeAudio(_ name: String, to folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0xCD, count: 2_048).write(to: url, options: [.atomic])
        return url
    }

    /// verbose_json transcription stub. See PipelineIntegrationTests for
    /// the same shape — `TranscriptionClient` decodes JSON since v0.4.2.
    private static func okResponse(body text: String) -> (HTTPURLResponse, Data) {
        let r = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "application/json"])!
        let payload: [String: Any] = [
            "task": "transcribe", "language": "english", "duration": 1.0,
            "text": text,
            "segments": [["id": 0, "start": 0.0, "end": 1.0, "text": text]]
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload, options: [])
        return (r, body)
    }

    @MainActor
    final class Capture {
        var entries: [AuditLogEntry] = []
        var notionUpdates: [(UUID, NotionStatus)] = []
    }

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

    @MainActor
    private static func makePipeline(
        watch: URL, output: URL, ledger: ProcessedFilesLedger,
        session: URLSession,
        capture: Capture,
        notionMode: NotionPipelineMode?
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
            onStateChange: { _ in },
            onAuditEntry: { entry in
                Task { @MainActor in capture.entries.append(entry) }
            },
            consumeMeetingContext: nil,
            notionMode: notionMode,
            onNotionStatusChange: { id, status in
                Task { @MainActor in capture.notionUpdates.append((id, status)) }
            }
        )
    }

    // MARK: - .attempt success

    @Test
    @MainActor
    func attemptMode_onSuccess_writesPendingThenSucceededStatus() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed body") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }

        let writer = FakeNotionMeetingWriter()
        let notionPageURL = URL(string: "https://www.notion.so/Page-deadbeef")!
        writer.nextResult = .success(NotionPageResult(pageId: "p1", url: notionPageURL))

        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            notionMode: .attempt(config: Self.notionConfig, writer: writer)
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("alpha.mp3", to: watch)

        // Wait for the .succeeded notification.
        let updated = await Self.waitForCondition {
            capture.notionUpdates.contains {
                if case .succeeded = $0.1 { return true }
                return false
            }
        }
        #expect(updated)

        // Initial success entry has .pending; later update flips to .succeeded.
        let initialSuccess = capture.entries.first { $0.kind == .success }
        #expect(initialSuccess?.notionStatus == .pending)

        let (entryId, finalStatus) = try #require(
            capture.notionUpdates.first(where: {
                if case .succeeded = $0.1 { return true }
                return false
            })
        )
        #expect(entryId == initialSuccess?.id)
        if case .succeeded(let url) = finalStatus {
            #expect(url == notionPageURL)
        } else {
            Issue.record("Expected .succeeded, got \(finalStatus)")
        }

        // Writer was called with the right inputs.
        #expect(writer.calls.count == 1)
        let call = try #require(writer.calls.first)
        // v0.4.4: Notion gets the timestamped rendering. Our mock
        // produces a single segment 0–1s carrying the body text, which
        // renders as `[00:00:00] transcribed body`.
        #expect(call.transcript == "[00:00:00] transcribed body")
        #expect(call.config.databaseId == Self.notionConfig.databaseId)
        // No snapshot was wired, so meetingName falls back to audio basename
        // and additionalContext is empty (PRD §4.3 — empty Additional Context
        // still produces the section, just empty).
        #expect(call.meetingName == "alpha")
        #expect(call.additionalContext == "")
    }

    // MARK: - .attempt failure

    @Test
    @MainActor
    func attemptMode_onWriterFailure_writesFailedStatus() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }

        let writer = FakeNotionMeetingWriter()
        writer.nextResult = .failure(.unauthorized)

        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            notionMode: .attempt(config: Self.notionConfig, writer: writer)
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("beta.mp3", to: watch)

        let got = await Self.waitForCondition {
            capture.notionUpdates.contains {
                if case .failed = $0.1 { return true }
                return false
            }
        }
        #expect(got)

        // Core pipeline still succeeded — failed Notion does not affect
        // the success audit entry's kind.
        let success = capture.entries.first { $0.kind == .success }
        #expect(success != nil)
        #expect(success?.notionStatus == .pending)

        // Update message reflects the typed error's userFacingMessage.
        let failure = capture.notionUpdates.first {
            if case .failed = $0.1 { return true }
            return false
        }
        if case .failed(let message) = failure?.1 {
            #expect(message.contains("Notion") || message.lowercased().contains("token"))
        }
    }

    // MARK: - .skip

    @Test
    @MainActor
    func skipMode_disabled_writesSkippedDisabledOnEntry_andDoesNotCallWriter() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed") }

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
            notionMode: .skip(reason: .disabled)
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("gamma.mp3", to: watch)

        let gotSuccess = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(gotSuccess)

        let success = capture.entries.first { $0.kind == .success }
        #expect(success?.notionStatus == .skipped(reason: .disabled))

        // Give the (cancelled, anyway) Notion task time NOT to fire an
        // onNotionStatusChange — we shouldn't see any updates.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(capture.notionUpdates.isEmpty)
    }

    @Test
    @MainActor
    func skipMode_misconfigured_writesSkippedMisconfiguredOnEntry() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed") }

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
            notionMode: .skip(reason: .misconfigured)
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("delta.mp3", to: watch)

        let gotSuccess = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(gotSuccess)

        let success = capture.entries.first { $0.kind == .success }
        #expect(success?.notionStatus == .skipped(reason: .misconfigured))
    }

    // MARK: - No mode (test default / legacy)

    @Test
    @MainActor
    func noMode_leavesNotionStatusNil() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed") }

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
            notionMode: nil
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("epsilon.mp3", to: watch)
        let gotSuccess = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(gotSuccess)
        let success = capture.entries.first { $0.kind == .success }
        #expect(success?.notionStatus == nil)
    }
}
