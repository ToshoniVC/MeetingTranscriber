import Testing
import Foundation
@testable import Jot

/// Phase H cross-phase smoke test: walks the full Add Context path from
/// organization setup through pipeline output and audit log.
///
/// Skips the SwiftUI prompter and the hotkey/Carbon machinery — we drive
/// `MeetingContextStore.recordStarted` directly with what the prompter
/// would have produced. Everything from there on (compile, consume,
/// transcribe, file-organize, audit) is the real code path.
@Suite(.serialized)
struct AddContextEndToEndIntegrationTests {

    private static let baseURL = URL(string: "https://api.test/v1/audio/transcriptions")!

    private static func makeFolders() throws -> (watch: URL, output: URL, ledger: ProcessedFilesLedger) {
        let watch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-e2e-watch-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-e2e-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-e2e-ledger-\(UUID().uuidString).json")
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
        var states: [PipelineState] = []
        var entries: [AuditLogEntry] = []
    }

    @Test
    @MainActor
    func fullFlow_orgConfiguredMeetingRecorded_endsWithContextMDAndOrgInAudit() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            let resp = HTTPURLResponse(url: Self.baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data("the standup transcript".utf8))
        }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }

        // 1. User has configured an organization in the Context tab.
        let orgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-e2e-orgs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: orgURL) }
        let orgStore = OrganizationStore(fileURL: orgURL)
        let acme = try orgStore.upsert(Organization(
            name: "Acme",
            staffNames: ["Alice", "Bob"],
            acronyms: [AcronymEntry(term: "MRR", expansion: "Monthly Recurring Revenue")],
            isDefault: true
        ))

        // 2. User triggers a recording. HotkeyCoordinator-equivalent: stamp
        // the snapshot directly with the compiled prompt.
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
            at: Date().addingTimeInterval(-1)
        )

        // 3. Wire the pipeline as PipelineCoordinator would.
        let capture = Capture()
        let watcher = try await FolderWatcher(
            folderURL: watch,
            stableDuration: 0.3,
            recheckInterval: 0.2,
            ledger: ledger
        )
        let pipeline = ProcessingPipeline(
            config: PipelineConfig(
                watchFolder: watch,
                outputFolder: output,
                apiBaseURL: Self.baseURL,
                model: "whisper-test",
                apiKey: "sk-test"
            ),
            watcher: watcher,
            transcriptionClient: TranscriptionClient(session: MockURLSession.make()),
            fileOrganizer: FileOrganizer(),
            onStateChange: { state in
                Task { @MainActor in capture.states.append(state) }
            },
            onAuditEntry: { entry in
                Task { @MainActor in capture.entries.append(entry) }
            },
            consumeMeetingContext: { creationDate in
                await MainActor.run { contextStore.consume(forFileCreatedAt: creationDate) }
            }
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        // 4. Audio Hijack drops a timestamp-named file.
        let audio = watch.appendingPathComponent("2026-05-28_15-30-00.mp3")
        try Data(repeating: 0xAA, count: 2_048).write(to: audio)

        // 5. Wait for the pipeline to produce a success entry.
        let succeeded = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(succeeded, "Pipeline did not produce a success entry: \(capture.entries.map(\.message))")

        // 6a. Renamed-and-filed meeting folder + transcript.
        let meeting = output.appendingPathComponent("Standup", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: meeting.path(percentEncoded: false)))
        let transcriptText = try String(
            contentsOf: meeting.appendingPathComponent("Standup.txt"),
            encoding: .utf8
        )
        #expect(transcriptText == "the standup transcript")

        // 6b. Audio was moved into the meeting folder.
        #expect(FileManager.default.fileExists(
            atPath: meeting.appendingPathComponent("Standup.mp3").path(percentEncoded: false)
        ))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: watch.path(percentEncoded: false))
        #expect(leftovers.isEmpty)

        // 6c. context.md alongside the transcript with the compiled prompt.
        let contextURL = meeting.appendingPathComponent("context.md")
        #expect(FileManager.default.fileExists(atPath: contextURL.path(percentEncoded: false)))
        let contextBody = try String(contentsOf: contextURL, encoding: .utf8)
        #expect(contextBody.contains("Organization: Acme"))
        #expect(contextBody.contains("Staff: Alice, Bob"))
        #expect(contextBody.contains("MRR = Monthly Recurring Revenue"))
        #expect(contextBody.contains("Quarterly review of MRR."))

        // 6d. Audit log records context attached + org name.
        let success = capture.entries.first { $0.kind == .success }
        #expect(success?.contextAttached == true)
        #expect(success?.organizationName == "Acme")
        #expect(success?.schemaVersion == 2)
    }

    /// Regression test for the no-orgs path: a user who never opens the
    /// Context tab and never picks an org should see exactly the
    /// pre-Add-Context behavior — file processed, no prompt sent, no
    /// context.md written, audit row carries contextAttached=nil (no
    /// pipeline ran a snapshot through).
    @Test
    @MainActor
    func legacyFlow_noSnapshot_pipelineBehavesAsBefore() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            let resp = HTTPURLResponse(url: Self.baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data("legacy".utf8))
        }

        let (watch, output, ledger) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }

        let capture = Capture()
        let watcher = try await FolderWatcher(
            folderURL: watch,
            stableDuration: 0.3,
            recheckInterval: 0.2,
            ledger: ledger
        )
        let pipeline = ProcessingPipeline(
            config: PipelineConfig(
                watchFolder: watch,
                outputFolder: output,
                apiBaseURL: Self.baseURL,
                model: "whisper-test",
                apiKey: "sk-test"
            ),
            watcher: watcher,
            transcriptionClient: TranscriptionClient(session: MockURLSession.make()),
            fileOrganizer: FileOrganizer(),
            onStateChange: { state in
                Task { @MainActor in capture.states.append(state) }
            },
            onAuditEntry: { entry in
                Task { @MainActor in capture.entries.append(entry) }
            },
            consumeMeetingContext: nil
        )
        try await pipeline.start()
        defer { Task { await pipeline.stop() } }

        let audio = watch.appendingPathComponent("untouched.mp3")
        try Data(repeating: 0xCC, count: 1_024).write(to: audio)

        let succeeded = await Self.waitForCondition {
            capture.entries.contains { $0.kind == .success }
        }
        #expect(succeeded)

        // Output folder named after the original file.
        let meeting = output.appendingPathComponent("untouched", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: meeting.path(percentEncoded: false)))

        // No context.md — there was no snapshot to compile from.
        let contextURL = meeting.appendingPathComponent("context.md")
        #expect(!FileManager.default.fileExists(atPath: contextURL.path(percentEncoded: false)))

        // Audit row: no consumeMeetingContext means snapshot was nil
        // throughout → contextAttached is false (we did consider but
        // didn't attach). organizationName stays nil.
        let success = capture.entries.first { $0.kind == .success }
        #expect(success?.contextAttached == false)
        #expect(success?.organizationName == nil)
    }
}
