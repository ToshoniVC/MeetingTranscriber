import Testing
import Foundation
@testable import Jot

/// Unit + integration tests for `TranscriptsViewModel`. Uses a real
/// `FileManager` against fresh tmpdirs — file listing logic is genuinely
/// the unit's main responsibility, so the integration view is the
/// substantive test.
@MainActor
struct TranscriptsViewModelTests {

    // MARK: - Helpers

    private static func makeOutputFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-transcripts-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Make a meeting folder with one .mp3 and one .txt inside, returning
    /// the folder URL.
    @discardableResult
    private static func makeMeetingFolder(
        _ name: String,
        in outputFolder: URL,
        audioExtension: String = "mp3"
    ) throws -> URL {
        let folder = outputFolder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let audio = folder.appendingPathComponent("\(name).\(audioExtension)")
        let transcript = folder.appendingPathComponent("\(name).txt")
        try Data(repeating: 0xCC, count: 4_096).write(to: audio)
        try "transcript text".data(using: .utf8)!.write(to: transcript)
        return folder
    }

    // MARK: - Empty / nil cases

    @Test
    func refresh_nilFolder_clearsMeetings() async {
        let viewModel = TranscriptsViewModel()
        await viewModel.refresh(outputFolder: nil)
        #expect(viewModel.meetings.isEmpty)
        #expect(viewModel.lastError == nil)
    }

    @Test
    func refresh_emptyOutputFolder_returnsEmptyMeetings() async throws {
        let folder = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let viewModel = TranscriptsViewModel()
        await viewModel.refresh(outputFolder: folder)
        #expect(viewModel.meetings.isEmpty)
        #expect(viewModel.lastError == nil)
    }

    @Test
    func refresh_nonexistentFolder_setsLastError() async {
        let bogus = URL(fileURLWithPath: "/never/exists-\(UUID().uuidString)")
        let viewModel = TranscriptsViewModel()
        await viewModel.refresh(outputFolder: bogus)
        #expect(viewModel.meetings.isEmpty)
        #expect(viewModel.lastError != nil)
    }

    // MARK: - Listing

    @Test
    func refresh_findsMeetingFolderWithBothFiles() async throws {
        let output = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: output) }

        let _ = try Self.makeMeetingFolder("2026-05-27_Standup", in: output)

        let viewModel = TranscriptsViewModel()
        await viewModel.refresh(outputFolder: output)
        #expect(viewModel.meetings.count == 1)
        let meeting = try #require(viewModel.meetings.first)
        #expect(meeting.name == "2026-05-27_Standup")
        #expect(meeting.files.count == 2)
        #expect(meeting.audioFile != nil)
        #expect(meeting.transcriptFile != nil)
    }

    @Test
    func refresh_sortsByModifiedDateNewestFirst() async throws {
        let output = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: output) }

        // Make three folders. Touch them with explicit mtimes so the test
        // is deterministic.
        let older = try Self.makeMeetingFolder("older", in: output)
        let middle = try Self.makeMeetingFolder("middle", in: output)
        let newer = try Self.makeMeetingFolder("newer", in: output)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_000)],
            ofItemAtPath: older.path(percentEncoded: false)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -1_500)],
            ofItemAtPath: middle.path(percentEncoded: false)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -100)],
            ofItemAtPath: newer.path(percentEncoded: false)
        )

        let viewModel = TranscriptsViewModel()
        await viewModel.refresh(outputFolder: output)
        #expect(viewModel.meetings.map(\.name) == ["newer", "middle", "older"])
    }

    @Test
    func refresh_skipsHiddenFolders() async throws {
        let output = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: output) }

        let _ = try Self.makeMeetingFolder("real-meeting", in: output)
        // Create a hidden folder by name.
        try FileManager.default.createDirectory(
            at: output.appendingPathComponent(".cache"),
            withIntermediateDirectories: false
        )

        let viewModel = TranscriptsViewModel()
        await viewModel.refresh(outputFolder: output)
        #expect(viewModel.meetings.map(\.name) == ["real-meeting"])
    }

    @Test
    func refresh_skipsLooseFilesAtTopLevel() async throws {
        let output = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: output) }

        let _ = try Self.makeMeetingFolder("meeting", in: output)
        // A stray file at the top level (not in a meeting folder) shouldn't
        // appear in the meeting list.
        try "stray".data(using: .utf8)!.write(
            to: output.appendingPathComponent("readme.txt")
        )

        let viewModel = TranscriptsViewModel()
        await viewModel.refresh(outputFolder: output)
        #expect(viewModel.meetings.map(\.name) == ["meeting"])
    }

    @Test
    func refresh_m4aFile_isRecognizedAsAudio() async throws {
        let output = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: output) }

        let _ = try Self.makeMeetingFolder("m4a-meeting", in: output, audioExtension: "m4a")
        let viewModel = TranscriptsViewModel()
        await viewModel.refresh(outputFolder: output)
        let meeting = try #require(viewModel.meetings.first)
        #expect(meeting.audioFile?.ext == "m4a")
    }

    // MARK: - Actions

    @Test
    func revealInFinder_callsWorkspace() async throws {
        let workspace = RecordingWorkspaceActions()
        let viewModel = TranscriptsViewModel(workspace: workspace)
        let url = URL(fileURLWithPath: "/tmp/anything")
        viewModel.revealInFinder(url)
        #expect(workspace.revealCalls == [url])
    }

    @Test
    func openInDefaultApp_callsWorkspace() async throws {
        let workspace = RecordingWorkspaceActions()
        let viewModel = TranscriptsViewModel(workspace: workspace)
        let url = URL(fileURLWithPath: "/tmp/anything.txt")
        viewModel.openInDefaultApp(url)
        #expect(workspace.openCalls == [url])
    }

    @Test
    func moveToTrash_removesFolder_andRowDisappearsFromMeetings() async throws {
        let output = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: output) }
        let folder = try Self.makeMeetingFolder("doomed", in: output)

        let viewModel = TranscriptsViewModel()
        await viewModel.refresh(outputFolder: output)
        #expect(viewModel.meetings.count == 1)

        let ok = await viewModel.moveToTrash(folder)
        #expect(ok)
        #expect(viewModel.meetings.isEmpty)
        // Source no longer in place.
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    // MARK: - Rename

    @Test
    func rename_validNewName_movesFolderAndReturnsNewURL() async throws {
        let output = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: output) }
        let folder = try Self.makeMeetingFolder("original", in: output)

        let viewModel = TranscriptsViewModel()
        let newURL = await viewModel.rename(folder, to: "renamed-meeting")
        #expect(newURL != nil)
        #expect(newURL?.lastPathComponent == "renamed-meeting")
        #expect(FileManager.default.fileExists(atPath: newURL!.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    @Test
    func rename_emptyName_returnsNil_andSetsError() async throws {
        let output = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: output) }
        let folder = try Self.makeMeetingFolder("original", in: output)

        let viewModel = TranscriptsViewModel()
        let result = await viewModel.rename(folder, to: "   ")
        #expect(result == nil)
        #expect(viewModel.lastError != nil)
    }

    @Test
    func rename_nameWithSlash_isRejected() async throws {
        let output = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: output) }
        let folder = try Self.makeMeetingFolder("original", in: output)

        let viewModel = TranscriptsViewModel()
        let result = await viewModel.rename(folder, to: "bad/name")
        #expect(result == nil)
        #expect(viewModel.lastError != nil)
    }

    @Test
    func rename_toExistingName_isRejected() async throws {
        let output = try Self.makeOutputFolder()
        defer { try? FileManager.default.removeItem(at: output) }
        let folder = try Self.makeMeetingFolder("alpha", in: output)
        let _ = try Self.makeMeetingFolder("bravo", in: output)

        let viewModel = TranscriptsViewModel()
        let result = await viewModel.rename(folder, to: "bravo")
        #expect(result == nil)
        #expect(viewModel.lastError != nil)
    }
}
