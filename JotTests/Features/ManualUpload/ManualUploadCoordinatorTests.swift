import Testing
import Foundation
@testable import Jot

/// Coordinator-level tests for the manual-upload flow. We inject stub
/// picker + prompter + watch-folder resolver so the coordinator runs
/// in-process against tmpdirs and the `MeetingContextStore` actually
/// receives the snapshot — proving the watcher-pipeline bridge will
/// work end-to-end when the real pipeline is wired.
@MainActor
struct ManualUploadCoordinatorTests {

    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-coord-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cleanUp(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private static func putFile(named name: String, in folder: URL, bytes: Int = 64) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private struct Fixture {
        let coordinator: ManualUploadCoordinator
        let settings: AppSettings
        let auditLog: AuditLogStore
        let organizations: OrganizationStore
        let meetingContextStore: MeetingContextStore
        let prompter: StubMeetingUploadPrompter
        let picker: StubManualUploadFilePicker
        let watchFolder: URL
    }

    private static func makeFixture(watchFolder: URL) -> Fixture {
        let defaults = EphemeralUserDefaults.make()
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let auditLog = AuditLogStore()
        let organizations = OrganizationStore()
        let meetingContextStore = MeetingContextStore()
        let prompter = StubMeetingUploadPrompter()
        let picker = StubManualUploadFilePicker()
        let coordinator = ManualUploadCoordinator(
            settings: settings,
            auditLog: auditLog,
            organizations: organizations,
            meetingContextStore: meetingContextStore,
            prompter: prompter,
            staging: ManualUploadStagingService(),
            conversion: MediaConversionService(),
            filePicker: picker,
            watchFolderResolver: { watchFolder }
        )
        return Fixture(
            coordinator: coordinator,
            settings: settings,
            auditLog: auditLog,
            organizations: organizations,
            meetingContextStore: meetingContextStore,
            prompter: prompter,
            picker: picker,
            watchFolder: watchFolder
        )
    }

    // MARK: - Happy path (mp3)

    @Test
    func beginUpload_mp3_stagesIntoWatchFolderAndStampsContext() async throws {
        let pickedDir = try Self.makeTempDir()
        let watchDir = try Self.makeTempDir()
        defer { Self.cleanUp(pickedDir, watchDir) }
        let source = try Self.putFile(named: "Client Call.mp3", in: pickedDir, bytes: 256)

        let f = Self.makeFixture(watchFolder: watchDir)
        f.picker.nextResponse = source
        f.prompter.nextResponse = MeetingStartInputs(
            meetingName: "Q3 Client Call",
            organizationId: nil,
            meetingSpecificContext: "Project Atlas"
        )

        await f.coordinator.beginUpload()

        #expect(f.coordinator.status == .idle)
        let staged = watchDir.appendingPathComponent("Client Call.mp3")
        #expect(FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)),
                "Staging should copy the file into the watch folder.")
        // Source must remain at its original location (copy, not move).
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))

        // MeetingContextStore must have a snapshot ready for the watcher
        // pipeline to consume on file-arrival.
        let snapshot = f.meetingContextStore.pending?.snapshot
        #expect(snapshot?.meetingName == "Q3 Client Call")
        #expect(snapshot?.meetingSpecificContext == "Project Atlas")
        // recordStopped was called so the window has an upper bound, but
        // the snapshot remains until the pipeline consumes it.
        #expect(f.meetingContextStore.pending?.stoppedAt != nil)
    }

    // MARK: - User cancellations

    @Test
    func beginUpload_userCancelsPicker_doesNotStampOrStage() async throws {
        let watchDir = try Self.makeTempDir()
        defer { Self.cleanUp(watchDir) }
        let f = Self.makeFixture(watchFolder: watchDir)
        f.picker.nextResponse = nil

        await f.coordinator.beginUpload()

        #expect(f.coordinator.status == .idle)
        #expect(f.meetingContextStore.pending == nil)
        let entries = try FileManager.default.contentsOfDirectory(atPath: watchDir.path)
        #expect(entries.isEmpty)
    }

    @Test
    func beginUpload_userCancelsMetadata_doesNotStage() async throws {
        let pickedDir = try Self.makeTempDir()
        let watchDir = try Self.makeTempDir()
        defer { Self.cleanUp(pickedDir, watchDir) }
        let source = try Self.putFile(named: "clip.mp3", in: pickedDir)
        let f = Self.makeFixture(watchFolder: watchDir)
        f.picker.nextResponse = source
        f.prompter.nextResponse = nil

        await f.coordinator.beginUpload()

        #expect(f.coordinator.status == .idle)
        #expect(f.meetingContextStore.pending == nil)
        let entries = try FileManager.default.contentsOfDirectory(atPath: watchDir.path)
        #expect(entries.isEmpty)
    }

    @Test
    func beginUpload_blankMeetingName_failsAndDoesNotStage() async throws {
        let pickedDir = try Self.makeTempDir()
        let watchDir = try Self.makeTempDir()
        defer { Self.cleanUp(pickedDir, watchDir) }
        let source = try Self.putFile(named: "clip.mp3", in: pickedDir)
        let f = Self.makeFixture(watchFolder: watchDir)
        f.picker.nextResponse = source
        f.prompter.nextResponse = MeetingStartInputs(meetingName: "   ")

        await f.coordinator.beginUpload()

        if case .failed = f.coordinator.status {
            // expected
        } else {
            Issue.record("Expected coordinator to land on .failed; got \(f.coordinator.status)")
        }
        #expect(f.meetingContextStore.pending == nil)
    }

    // MARK: - Configuration gating

    @Test
    func beginUpload_noWatchFolder_failsWithUnreachable() async throws {
        let defaults = EphemeralUserDefaults.make()
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let auditLog = AuditLogStore()
        let organizations = OrganizationStore()
        let store = MeetingContextStore()
        let prompter = StubMeetingUploadPrompter()
        let picker = StubManualUploadFilePicker()
        let coordinator = ManualUploadCoordinator(
            settings: settings,
            auditLog: auditLog,
            organizations: organizations,
            meetingContextStore: store,
            prompter: prompter,
            staging: ManualUploadStagingService(),
            conversion: MediaConversionService(),
            filePicker: picker,
            watchFolderResolver: { nil }
        )

        await coordinator.beginUpload()

        if case .failed(let message) = coordinator.status {
            #expect(message.contains("Watch Folder"))
        } else {
            Issue.record("Expected .failed; got \(coordinator.status)")
        }
        // Picker should NOT have been opened — we fail fast on the
        // missing config gate.
        #expect(picker.pickCount == 0)
    }

    // MARK: - dismissFailure

    @Test
    func dismissFailure_returnsToIdle() async throws {
        let watchDir = try Self.makeTempDir()
        defer { Self.cleanUp(watchDir) }
        let f = Self.makeFixture(watchFolder: watchDir)
        f.picker.nextResponse = nil // forces a userCancelled but that maps to .idle…
        // Force a .failed state directly by attempting with no watch folder.
        let bad = ManualUploadCoordinator(
            settings: f.settings,
            auditLog: f.auditLog,
            organizations: f.organizations,
            meetingContextStore: f.meetingContextStore,
            prompter: f.prompter,
            staging: ManualUploadStagingService(),
            conversion: MediaConversionService(),
            filePicker: f.picker,
            watchFolderResolver: { nil }
        )
        await bad.beginUpload()
        if case .failed = bad.status {
            bad.dismissFailure()
            #expect(bad.status == .idle)
        } else {
            Issue.record("Setup did not produce a failed state")
        }
    }
}

// MARK: - v0.5.1 multi-file + ledger forget

/// Sink that records what the `MeetingBatchAccumulator` emits, so the
/// multi-file tests can assert "this batch closed with N parts" without
/// running the real pipeline.
private actor BatchSink {
    private(set) var items: [PipelineWorkItem] = []
    func record(_ item: PipelineWorkItem) { items.append(item) }
    func snapshot() async -> [PipelineWorkItem] { items }
}

@MainActor
struct ManualUploadCoordinatorMultiFileTests {

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-coord-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func putFile(named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: 128).write(to: url)
        return url
    }

    private struct MultiFixture {
        let coordinator: ManualUploadCoordinator
        let auditLog: AuditLogStore
        let prompter: StubMeetingUploadPrompter
        let picker: StubManualUploadFilePicker
        let accumulator: MeetingBatchAccumulator
        let ledger: ProcessedFilesLedger
        let watchFolder: URL
    }

    /// Build a fixture wired to a real `MeetingBatchAccumulator` + a
    /// `ProcessedFilesLedger` backed by a tmpdir file, plus a `BatchSink`
    /// emitter so multi-file tests can read what the accumulator
    /// produced after `noteRecordingStopped`.
    private static func makeFixture(
        watchFolder: URL,
        ledgerFile: URL,
        settleDelay: TimeInterval = 0.05
    ) async -> (MultiFixture, BatchSink) {
        let defaults = EphemeralUserDefaults.make()
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let auditLog = AuditLogStore()
        let organizations = OrganizationStore()
        let meetingContextStore = MeetingContextStore()
        let accumulator = MeetingBatchAccumulator(settleDelay: settleDelay)
        let ledger = ProcessedFilesLedger(url: ledgerFile)
        let prompter = StubMeetingUploadPrompter()
        let picker = StubManualUploadFilePicker()
        let sink = BatchSink()
        await accumulator.setEmitter { item in
            await sink.record(item)
        }
        let coordinator = ManualUploadCoordinator(
            settings: settings,
            auditLog: auditLog,
            organizations: organizations,
            meetingContextStore: meetingContextStore,
            batchAccumulator: accumulator,
            processedFilesLedger: ledger,
            prompter: prompter,
            staging: ManualUploadStagingService(),
            conversion: MediaConversionService(),
            filePicker: picker,
            watchFolderResolver: { watchFolder }
        )
        let fixture = MultiFixture(
            coordinator: coordinator,
            auditLog: auditLog,
            prompter: prompter,
            picker: picker,
            accumulator: accumulator,
            ledger: ledger,
            watchFolder: watchFolder
        )
        return (fixture, sink)
    }

    private static func waitForSettle(_ extra: TimeInterval = 0.1) async {
        try? await Task.sleep(nanoseconds: UInt64((0.05 + extra) * 1_000_000_000))
    }

    // MARK: - Multi-file happy path

    @Test
    func multiFileUpload_stagesAllPartsIntoWatchFolder() async throws {
        let sourceDir = try Self.makeTempDir()
        let watchDir = try Self.makeTempDir()
        let ledgerFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-ledger-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: watchDir)
            try? FileManager.default.removeItem(at: ledgerFile)
        }

        let p1 = try Self.putFile(named: "UKG (part 1).mp3", in: sourceDir)
        let p2 = try Self.putFile(named: "UKG (part 2).mp3", in: sourceDir)
        let p3 = try Self.putFile(named: "UKG (part 3).mp3", in: sourceDir)

        let (f, _) = await Self.makeFixture(watchFolder: watchDir, ledgerFile: ledgerFile)
        f.picker.nextResponses = [p1, p2, p3]
        f.prompter.nextResponse = MeetingStartInputs(
            meetingName: "UKG Labs Intro",
            organizationId: nil,
            meetingSpecificContext: nil
        )

        await f.coordinator.beginUpload()

        // All 3 staged into the Watch Folder under their original names.
        let stagedNames = try FileManager.default
            .contentsOfDirectory(atPath: watchDir.path(percentEncoded: false))
            .sorted()
        #expect(stagedNames == ["UKG (part 1).mp3", "UKG (part 2).mp3", "UKG (part 3).mp3"])

        // Coordinator settled into idle (the accumulator-to-pipeline
        // delivery happens via the watcher in production; here we just
        // verify the coordinator's own responsibilities: stage all and
        // surface the success message in the audit log).
        if case .failed = f.coordinator.status {
            Issue.record("Coordinator failed unexpectedly: \(f.coordinator.status)")
        }
        let messages = f.auditLog.entries.map(\.message).joined(separator: "\n")
        #expect(messages.contains("3 parts"),
                "Expected an audit row mentioning 3 staged parts, got: \(messages)")
    }

    /// Verify the multi-file path actually drives the accumulator (not
    /// some sneaky single-file fallback) by checking that the coordinator
    /// opens + closes a recording window. We do this by ingesting one
    /// staged file *during* the window and asserting the accumulator
    /// buffered it (rather than emitting `.single` immediately, which is
    /// what happens when no session is open).
    @Test
    func multiFileUpload_opensAccumulatorRecordingWindow() async throws {
        let sourceDir = try Self.makeTempDir()
        let watchDir = try Self.makeTempDir()
        let ledgerFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-ledger-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: watchDir)
            try? FileManager.default.removeItem(at: ledgerFile)
        }

        let p1 = try Self.putFile(named: "A.mp3", in: sourceDir)
        let p2 = try Self.putFile(named: "B.mp3", in: sourceDir)

        // Long settle delay so we have time to inspect post-stop state.
        let (f, sink) = await Self.makeFixture(
            watchFolder: watchDir,
            ledgerFile: ledgerFile,
            settleDelay: 1.0
        )
        f.picker.nextResponses = [p1, p2]
        f.prompter.nextResponse = MeetingStartInputs(
            meetingName: "Multi",
            organizationId: nil,
            meetingSpecificContext: nil
        )

        await f.coordinator.beginUpload()

        // Simulate the watcher: ingest the staged files into the
        // accumulator just like `routeFromWatcher` would. If the
        // coordinator correctly opened a window, these get buffered
        // and emit as `.batch` on settle. If it didn't, each emits as
        // `.single`.
        let stagedA = watchDir.appendingPathComponent("A.mp3")
        let stagedB = watchDir.appendingPathComponent("B.mp3")
        await f.accumulator.ingest(stagedA, creationDate: Date())
        await f.accumulator.ingest(stagedB, creationDate: Date())

        // Wait for the 1.0s settle to fire.
        try? await Task.sleep(nanoseconds: UInt64(1.2 * 1_000_000_000))

        let items = await sink.snapshot()
        // Expect exactly one batch with both parts. Anything else
        // (zero items, two singles) means the window wasn't open
        // when the watcher would have ingested.
        #expect(items.count == 1, "Expected one batch emission, got \(items.count): \(items)")
        if case .batch(let batch)? = items.first {
            #expect(batch.parts.count == 2)
            #expect(batch.snapshot.meetingName == "Multi")
        } else {
            Issue.record("Expected `.batch`, got \(String(describing: items.first))")
        }
    }

    // MARK: - Ledger forget

    @Test
    func upload_forgetsStaleLedgerEntryBeforeStaging() async throws {
        let sourceDir = try Self.makeTempDir()
        let watchDir = try Self.makeTempDir()
        let ledgerFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-ledger-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: watchDir)
            try? FileManager.default.removeItem(at: ledgerFile)
        }

        let source = try Self.putFile(named: "Re-upload.mp3", in: sourceDir)

        let (f, _) = await Self.makeFixture(watchFolder: watchDir, ledgerFile: ledgerFile)

        // Pre-load the ledger with the path the coordinator is about to
        // stage at — simulating a previous failed attempt. v0.5.0 would
        // have left this entry in place and the watcher would silently
        // skip the new copy.
        let expectedTarget = watchDir.appendingPathComponent("Re-upload.mp3")
        try await f.ledger.record(expectedTarget)
        #expect(await f.ledger.contains(expectedTarget))

        f.picker.nextResponse = source
        f.prompter.nextResponse = MeetingStartInputs(
            meetingName: "Q4 follow-up", organizationId: nil, meetingSpecificContext: nil
        )
        await f.coordinator.beginUpload()

        // The stale ledger entry for the target was cleared before
        // staging, then re-recorded by the staging step? No — we don't
        // record in the staging itself. The watcher records on emit,
        // which doesn't happen in this test (no watcher running). What
        // we assert: the entry the test pre-loaded is gone.
        #expect(!(await f.ledger.contains(expectedTarget)),
                "Coordinator must forget stale ledger entries before staging")
    }

    // MARK: - Guardrail

    @Test
    func multiFileUpload_withoutAccumulator_failsClearly() async throws {
        let sourceDir = try Self.makeTempDir()
        let watchDir = try Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: watchDir)
        }

        let p1 = try Self.putFile(named: "A.mp3", in: sourceDir)
        let p2 = try Self.putFile(named: "B.mp3", in: sourceDir)

        let defaults = EphemeralUserDefaults.make()
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let auditLog = AuditLogStore()
        let organizations = OrganizationStore()
        let meetingContextStore = MeetingContextStore()
        let prompter = StubMeetingUploadPrompter()
        let picker = StubManualUploadFilePicker()
        let coordinator = ManualUploadCoordinator(
            settings: settings,
            auditLog: auditLog,
            organizations: organizations,
            meetingContextStore: meetingContextStore,
            // Deliberately no batchAccumulator + no ledger.
            prompter: prompter,
            staging: ManualUploadStagingService(),
            conversion: MediaConversionService(),
            filePicker: picker,
            watchFolderResolver: { watchDir }
        )
        picker.nextResponses = [p1, p2]
        prompter.nextResponse = MeetingStartInputs(
            meetingName: "X", organizationId: nil, meetingSpecificContext: nil
        )

        await coordinator.beginUpload()

        if case .failed(let message) = coordinator.status {
            #expect(message.lowercased().contains("multi-file"),
                    "Failure message should explain why multi-file isn't supported here: \(message)")
        } else {
            Issue.record("Expected coordinator to fail when accumulator missing; status=\(coordinator.status)")
        }
    }
}

