import Testing
import Foundation
@testable import Jot

/// Pipeline tests covering the post-Notion Claude Code routine trigger.
/// Use the real `FolderWatcher` + `FileOrganizer`, a `URLProtocol`-mocked
/// transcription endpoint, a `FakeNotionMeetingWriter` for the Notion
/// hop, and a `FakeClaudeCodeRoutineFiring` so we can assert the
/// post-Notion fire happens with the right inputs and only when the
/// PRD's preconditions are met.
@Suite(.serialized)
struct ProcessingPipelineClaudeCodeTests {

    private static let baseURL = URL(string: "https://api.test/v1/audio/transcriptions")!
    private static let notionConfig = NotionConfig(
        token: "secret_test",
        databaseId: "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
    )
    private static let claudeCodeConfig = ClaudeCodeRoutineConfig(
        endpoint: URL(string: "https://api.anthropic.com/v1/claude_code/routines/trg_abc/fire")!,
        token: "anthropic-bearer-token",
        extraText: ""
    )

    private static func makeFolders() throws -> (watch: URL, output: URL, ledger: ProcessedFilesLedger) {
        let watch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-pc-watch-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-pc-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-pc-ledger-\(UUID().uuidString).json")
        return (watch, output, ProcessedFilesLedger(url: ledgerURL))
    }

    private static func writeAudio(_ name: String, to folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0xCD, count: 2_048).write(to: url, options: [.atomic])
        return url
    }

    private static func okResponse(body: String) -> (HTTPURLResponse, Data) {
        let r = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (r, Data(body.utf8))
    }

    @MainActor
    final class Capture {
        var entries: [AuditLogEntry] = []
        var notionUpdates: [(UUID, NotionStatus)] = []
        var claudeCodeUpdates: [(UUID, ClaudeCodeRoutineStatus)] = []
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
        notionMode: NotionPipelineMode?,
        claudeCodeMode: ClaudeCodePipelineMode?
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
            },
            claudeCodeMode: claudeCodeMode,
            onClaudeCodeStatusChange: { id, status in
                Task { @MainActor in capture.claudeCodeUpdates.append((id, status)) }
            }
        )
    }

    // MARK: - Happy path: notion success → routine fires

    @Test
    @MainActor
    func attemptMode_onNotionSuccess_firesRoutine_withPageURLInBody() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed body") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }

        let writer = FakeNotionMeetingWriter()
        let notionPageURL = URL(string: "https://www.notion.so/Page-cafebabe")!
        writer.nextResult = .success(NotionPageResult(pageId: "p1", url: notionPageURL))

        let firing = FakeClaudeCodeRoutineFiring()

        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            notionMode: .attempt(config: Self.notionConfig, writer: writer),
            claudeCodeMode: .attempt(config: Self.claudeCodeConfig, firing: firing)
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("alpha.mp3", to: watch)

        let fired = await Self.waitForCondition {
            capture.claudeCodeUpdates.contains { $0.1 == .fired }
        }
        #expect(fired)

        // Fire happened exactly once and after Notion succeeded.
        #expect(firing.calls.count == 1)
        let call = try #require(firing.calls.first)
        // Body text includes the freshly-created Notion page URL so
        // the routine knows which page to write into.
        #expect(call.text.contains(notionPageURL.absoluteString))
        // No user-configured extra text → body starts with the footer.
        #expect(call.text.hasPrefix("Notion meeting page:"))
    }

    @Test
    @MainActor
    func attemptMode_appendsExtraText_aboveTheFooter() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let writer = FakeNotionMeetingWriter()
        writer.nextResult = .success(NotionPageResult(
            pageId: "p1",
            url: URL(string: "https://www.notion.so/Page-1")!
        ))

        let firing = FakeClaudeCodeRoutineFiring()
        let config = ClaudeCodeRoutineConfig(
            endpoint: Self.claudeCodeConfig.endpoint,
            token: Self.claudeCodeConfig.token,
            extraText: "Please write detailed action items."
        )

        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            notionMode: .attempt(config: Self.notionConfig, writer: writer),
            claudeCodeMode: .attempt(config: config, firing: firing)
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("beta.mp3", to: watch)
        let fired = await Self.waitForCondition {
            !firing.calls.isEmpty
        }
        #expect(fired)

        let text = try #require(firing.calls.first?.text)
        #expect(text.hasPrefix("Please write detailed action items."))
        #expect(text.contains("Notion meeting page:"))
    }

    // MARK: - Failure containment

    @Test
    @MainActor
    func attemptMode_onRoutineFireFailure_doesNotRegressNotionSuccess() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let writer = FakeNotionMeetingWriter()
        let notionPageURL = URL(string: "https://www.notion.so/Page-deadbeef")!
        writer.nextResult = .success(NotionPageResult(pageId: "p1", url: notionPageURL))

        let firing = FakeClaudeCodeRoutineFiring()
        firing.nextResult = .failure(.unauthorized)

        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            notionMode: .attempt(config: Self.notionConfig, writer: writer),
            claudeCodeMode: .attempt(config: Self.claudeCodeConfig, firing: firing)
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("gamma.mp3", to: watch)

        let gotFailure = await Self.waitForCondition {
            capture.claudeCodeUpdates.contains {
                if case .failed = $0.1 { return true }
                return false
            }
        }
        #expect(gotFailure)

        // Core pipeline + Notion are unchanged: success entry has
        // `.pending` Notion status (later .succeeded), and there's no
        // additional failure row.
        let success = capture.entries.first { $0.kind == .success }
        #expect(success != nil)
        let succeeded = capture.notionUpdates.contains {
            if case .succeeded = $0.1 { return true }
            return false
        }
        #expect(succeeded)
        #expect(capture.entries.filter { $0.kind == .failure }.isEmpty)
    }

    // MARK: - Notion failure short-circuits the routine

    @Test
    @MainActor
    func attemptMode_onNotionFailure_skipsRoutine_withReasonNotionNotReady() async throws {
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
        let firing = FakeClaudeCodeRoutineFiring()

        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            notionMode: .attempt(config: Self.notionConfig, writer: writer),
            claudeCodeMode: .attempt(config: Self.claudeCodeConfig, firing: firing)
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("delta.mp3", to: watch)

        let gotSkip = await Self.waitForCondition {
            capture.claudeCodeUpdates.contains { update in
                if case .skipped(.notionNotReady) = update.1 { return true }
                return false
            }
        }
        #expect(gotSkip)
        // Routine fire was NOT attempted.
        #expect(firing.calls.isEmpty)
    }

    // MARK: - Skip modes (disabled / misconfigured)

    @Test
    @MainActor
    func skipMode_disabled_stampsSkippedDisabled_andDoesNotCallFiring() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let writer = FakeNotionMeetingWriter()
        writer.nextResult = .success(NotionPageResult(
            pageId: "p1",
            url: URL(string: "https://www.notion.so/Page-1")!
        ))
        let firing = FakeClaudeCodeRoutineFiring()

        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            notionMode: .attempt(config: Self.notionConfig, writer: writer),
            claudeCodeMode: .skip(reason: .disabled)
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("epsilon.mp3", to: watch)
        let success = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(success)

        let entry = capture.entries.first { $0.kind == .success }
        #expect(entry?.claudeCodeStatus == .skipped(reason: .disabled))
        // No fire call, no in-flight update.
        #expect(firing.calls.isEmpty)
        // Wait briefly to confirm no async fire arrives later.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(capture.claudeCodeUpdates.isEmpty)
    }

    @Test
    @MainActor
    func skipMode_misconfigured_stampsSkippedMisconfigured() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let writer = FakeNotionMeetingWriter()
        writer.nextResult = .success(NotionPageResult(
            pageId: "p1",
            url: URL(string: "https://www.notion.so/Page-2")!
        ))
        let firing = FakeClaudeCodeRoutineFiring()

        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            notionMode: .attempt(config: Self.notionConfig, writer: writer),
            claudeCodeMode: .skip(reason: .misconfigured)
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("zeta.mp3", to: watch)
        let success = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(success)

        let entry = capture.entries.first { $0.kind == .success }
        #expect(entry?.claudeCodeStatus == .skipped(reason: .misconfigured))
        #expect(firing.calls.isEmpty)
    }

    // MARK: - No mode (test default)

    @Test
    @MainActor
    func noMode_leavesClaudeCodeStatusNil_andDoesNotFire() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.okResponse(body: "transcribed") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let writer = FakeNotionMeetingWriter()
        writer.nextResult = .success(NotionPageResult(
            pageId: "p1",
            url: URL(string: "https://www.notion.so/Page-3")!
        ))
        let firing = FakeClaudeCodeRoutineFiring()

        let capture = Capture()
        let pipeline = try await Self.makePipeline(
            watch: watch, output: output, ledger: ledger,
            session: MockURLSession.make(),
            capture: capture,
            notionMode: .attempt(config: Self.notionConfig, writer: writer),
            claudeCodeMode: nil
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        _ = try Self.writeAudio("eta.mp3", to: watch)
        let success = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(success)

        let entry = capture.entries.first { $0.kind == .success }
        #expect(entry?.claudeCodeStatus == nil)
        #expect(firing.calls.isEmpty)
    }
}
