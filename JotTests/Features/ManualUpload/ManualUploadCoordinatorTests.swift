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
