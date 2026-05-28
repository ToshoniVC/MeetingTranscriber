import Testing
import Foundation
@testable import Jot

/// Phase F cross-phase smoke tests: walk the full pipeline path with the
/// Notion bridge wired in. Use the real `FolderWatcher`, real
/// `FileOrganizer`, `URLProtocol`-mocked transcription, and a fake
/// `NotionMeetingWriter` so we can assert the exact call shape that
/// arrives at the writer without standing up two `MockURLProtocol`
/// responder branches in one test.
@Suite(.serialized)
struct NotionEndToEndIntegrationTests {

    private static let baseURL = URL(string: "https://api.test/v1/audio/transcriptions")!
    private static let notionConfig = NotionConfig(
        token: "secret_e2e",
        databaseId: "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
    )

    /// verbose_json transcription stub — `TranscriptionClient` decodes
    /// JSON since v0.4.2, so the e2e mock has to look like the real API.
    private static func transcriptionResponse(_ text: String) -> (HTTPURLResponse, Data) {
        let r = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "application/json"])!
        let payload: [String: Any] = [
            "task": "transcribe", "language": "english", "duration": 1.0,
            "text": text,
            "segments": [["id": 0, "start": 0.0, "end": 1.0, "text": text]]
        ]
        return (r, try! JSONSerialization.data(withJSONObject: payload, options: []))
    }

    private static func makeFolders() throws -> (watch: URL, output: URL, ledger: ProcessedFilesLedger) {
        let watch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-nx-watch-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-nx-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-nx-ledger-\(UUID().uuidString).json")
        return (watch, output, ProcessedFilesLedger(url: ledgerURL))
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
    final class Capture {
        var entries: [AuditLogEntry] = []
        var updates: [(UUID, NotionStatus)] = []
    }

    /// E2E happy path: user enables Notion, records a meeting with a
    /// configured organization, drops the file. We expect the transcript
    /// + audio + context.md on disk, the Notion writer called with the
    /// right inputs, and the audit row finishing with `.succeeded(url)`.
    @Test
    @MainActor
    func happyPath_recordedMeetingWithOrgAndNotion_endsWithSucceededRow() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.transcriptionResponse("the standup transcript") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }

        // 1. User has configured an organization with staff + acronyms.
        let orgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-nx-orgs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: orgURL) }
        let orgStore = OrganizationStore(fileURL: orgURL)
        let acme = try orgStore.upsert(Organization(
            name: "Acme",
            staffNames: ["Alice", "Bob"],
            acronyms: [AcronymEntry(term: "MRR", expansion: "Monthly Recurring Revenue")],
            isDefault: true
        ))

        // 2. User starts a meeting via the prompter equivalent.
        let contextStore = MeetingContextStore()
        let compiled = ContextCompiler.compile(
            meetingName: "Standup",
            meetingSpecificContext: "Quarterly review of MRR.",
            organization: acme
        )
        contextStore.recordStarted(
            meetingName: "Standup",
            organizationId: acme.id,
            organizationName: acme.name,
            meetingSpecificContext: "Quarterly review of MRR.",
            resolvedCompiledContext: compiled,
            at: Date()
        )

        // 3. Wire the pipeline with the fake Notion writer.
        let writer = FakeNotionMeetingWriter()
        let notionPageURL = URL(string: "https://www.notion.so/Standup-deadbeef")!
        writer.nextResult = .success(NotionPageResult(pageId: "p1", url: notionPageURL))

        let watcher = try await FolderWatcher(
            folderURL: watch,
            stableDuration: 0.3,
            recheckInterval: 0.2,
            ledger: ledger
        )
        let config = PipelineConfig(
            watchFolder: watch,
            outputFolder: output,
            apiBaseURL: Self.baseURL,
            model: "whisper-test",
            apiKey: "sk-test"
        )

        let capture = Capture()
        let pipeline = ProcessingPipeline(
            config: config,
            watcher: watcher,
            transcriptionClient: TranscriptionClient(session: MockURLSession.make()),
            fileOrganizer: FileOrganizer(),
            onStateChange: { _ in },
            onAuditEntry: { entry in
                Task { @MainActor in capture.entries.append(entry) }
            },
            consumeMeetingContext: { creationDate in
                await MainActor.run { contextStore.consume(forFileCreatedAt: creationDate) }
            },
            notionMode: .attempt(config: Self.notionConfig, writer: writer),
            onNotionStatusChange: { id, status in
                Task { @MainActor in capture.updates.append((id, status)) }
            }
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        // 4. Drop the audio file (Audio Hijack equivalent).
        let audio = watch.appendingPathComponent("placeholder.mp3")
        try Data(repeating: 0xCD, count: 2_048).write(to: audio, options: [.atomic])

        // 5. Wait for the Notion succeeded update.
        let updated = await Self.waitForCondition(timeout: 8.0) {
            capture.updates.contains {
                if case .succeeded = $0.1 { return true }
                return false
            }
        }
        #expect(updated)

        // 6a. Transcript + audio + context.md are on disk under the
        // Standup meeting folder (with a timestamp prefix).
        let outputEntries = try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))
        let meetingFolderName = try #require(outputEntries.first { $0.hasSuffix("Standup") })
        let meetingFolder = output.appendingPathComponent(meetingFolderName)
        let folderContents = try FileManager.default.contentsOfDirectory(atPath: meetingFolder.path(percentEncoded: false))
        #expect(folderContents.contains { $0.hasSuffix(".mp3") })
        #expect(folderContents.contains { $0.hasSuffix(".txt") })
        #expect(folderContents.contains { $0 == "context.md" })

        // 6b. Notion writer received the right call.
        #expect(writer.calls.count == 1)
        let call = try #require(writer.calls.first)
        #expect(call.meetingName == "Standup")
        // v0.4.4: Notion receives the timestamped rendering. The mock's
        // single 0–1s segment renders as `[00:00:00] the standup transcript`.
        #expect(call.transcript == "[00:00:00] the standup transcript")
        #expect(call.additionalContext.contains("Organization: Acme"))
        #expect(call.additionalContext.contains("MRR = Monthly Recurring Revenue"))
        #expect(call.config.databaseId == Self.notionConfig.databaseId)

        // 6c. Audit row started .pending, ended .succeeded(url).
        let successRow = capture.entries.first { $0.kind == .success }
        let success = try #require(successRow)
        #expect(success.notionStatus == .pending)
        #expect(success.contextAttached == true)
        #expect(success.organizationName == "Acme")
        let succeededUpdate = try #require(
            capture.updates.first(where: {
                if case .succeeded = $0.1 { return true }
                return false
            })
        )
        #expect(succeededUpdate.0 == success.id)
        if case .succeeded(let url) = succeededUpdate.1 {
            #expect(url == notionPageURL)
        }
    }

    /// Backwards-compat: a user with the toggle off — the default for
    /// every v0.2.x install — should see exactly the v0.2.x behavior:
    /// transcript + context.md on disk, no Notion calls, audit row with
    /// `.skipped(.disabled)`.
    @Test
    @MainActor
    func legacyDisabledFlow_dropsFile_makesNoNotionCalls() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.transcriptionResponse("plain transcript") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }

        let watcher = try await FolderWatcher(
            folderURL: watch,
            stableDuration: 0.3,
            recheckInterval: 0.2,
            ledger: ledger
        )
        let config = PipelineConfig(
            watchFolder: watch,
            outputFolder: output,
            apiBaseURL: Self.baseURL,
            model: "whisper-test",
            apiKey: "sk-test"
        )
        let capture = Capture()
        let pipeline = ProcessingPipeline(
            config: config,
            watcher: watcher,
            transcriptionClient: TranscriptionClient(session: MockURLSession.make()),
            fileOrganizer: FileOrganizer(),
            onStateChange: { _ in },
            onAuditEntry: { entry in
                Task { @MainActor in capture.entries.append(entry) }
            },
            consumeMeetingContext: nil,
            notionMode: .skip(reason: .disabled),
            onNotionStatusChange: { id, status in
                Task { @MainActor in capture.updates.append((id, status)) }
            }
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        let audio = watch.appendingPathComponent("legacy.mp3")
        try Data(repeating: 0xCD, count: 2_048).write(to: audio, options: [.atomic])

        let got = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(got)

        // Disabled-skip → audit row carries .skipped(.disabled). No
        // onNotionStatusChange ever fires.
        let success = try #require(capture.entries.first { $0.kind == .success })
        #expect(success.notionStatus == .skipped(reason: .disabled))

        // Give a beat for any rogue task to leak — there shouldn't be any.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(capture.updates.isEmpty)
    }

    // MARK: - Failure modes

    @Test
    @MainActor
    func notionFailure_doesNotAffectTranscriptOrContextOutput() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in Self.transcriptionResponse("transcript body") }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }

        let writer = FakeNotionMeetingWriter()
        writer.nextResult = .failure(.serverError(status: 500))

        let watcher = try await FolderWatcher(
            folderURL: watch,
            stableDuration: 0.3,
            recheckInterval: 0.2,
            ledger: ledger
        )
        let config = PipelineConfig(
            watchFolder: watch,
            outputFolder: output,
            apiBaseURL: Self.baseURL,
            model: "whisper-test",
            apiKey: "sk-test"
        )
        let capture = Capture()
        let pipeline = ProcessingPipeline(
            config: config,
            watcher: watcher,
            transcriptionClient: TranscriptionClient(session: MockURLSession.make()),
            fileOrganizer: FileOrganizer(),
            onStateChange: { _ in },
            onAuditEntry: { entry in
                Task { @MainActor in capture.entries.append(entry) }
            },
            consumeMeetingContext: nil,
            notionMode: .attempt(config: Self.notionConfig, writer: writer),
            onNotionStatusChange: { id, status in
                Task { @MainActor in capture.updates.append((id, status)) }
            }
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        let audio = watch.appendingPathComponent("zeta.mp3")
        try Data(repeating: 0xCD, count: 2_048).write(to: audio, options: [.atomic])

        // Wait for either succeeded or failed update.
        let got = await Self.waitForCondition {
            capture.updates.contains {
                if case .failed = $0.1 { return true }
                return false
            }
        }
        #expect(got)

        // The audit success row is unaffected by Notion failure — kind
        // remains .success, the transcript still lands on disk.
        let success = capture.entries.first { $0.kind == .success }
        #expect(success != nil)
        let outputEntries = try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))
        let meetingFolderName = try #require(outputEntries.first { $0.hasSuffix("zeta") })
        let meetingFolder = output.appendingPathComponent(meetingFolderName)
        let folderContents = try FileManager.default.contentsOfDirectory(atPath: meetingFolder.path(percentEncoded: false))
        #expect(folderContents.contains { $0.hasSuffix(".mp3") })
        #expect(folderContents.contains { $0.hasSuffix(".txt") })
    }
}
