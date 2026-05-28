import Testing
import Foundation
@testable import Jot

/// Integration tests for the multi-part variant of `FileOrganizer.organize`
/// introduced in v0.4.1 to handle Audio Hijack's split-file recordings.
/// Verifies that all parts land inside one meeting folder under their
/// original filenames, that the meeting folder + transcript pick up the
/// first part's basename, and that a mid-move failure rolls back cleanly.
struct FileOrganizerMultiPartTests {

    // MARK: - Helpers

    private static func makeWatchAndOutput() throws -> (watch: URL, output: URL) {
        let watch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-orgmp-watch-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-orgmp-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return (watch, output)
    }

    private static func cleanUp(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private static func putAudio(named name: String, in folder: URL, bytes: Int = 256) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    /// Tiny verbose_json stand-in for tests that don't care about the
    /// JSON contents — FileOrganizer only needs it to parse.
    private static func fakeTranscriptJSON(text: String = "T") -> Data {
        let payload: [String: Any] = [
            "text": text, "duration": 1.0,
            "segments": [["id": 0, "start": 0.0, "end": 1.0, "text": text]]
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [])
    }

    // MARK: - Happy path

    @Test
    func organize_threeParts_putsAllInsideOneFolder() async throws {
        let (watch, output) = try Self.makeWatchAndOutput()
        defer { Self.cleanUp(watch, output) }

        let p1 = try Self.putAudio(named: "2026.05.28 - 16.02 - BFTP call.mp3", in: watch)
        let p2 = try Self.putAudio(named: "2026.05.28 - 16.02 - BFTP call (part 2).mp3", in: watch)
        let p3 = try Self.putAudio(named: "2026.05.28 - 16.02 - BFTP call (part 3).mp3", in: watch)

        let organizer = FileOrganizer()
        let folder = try await organizer.organize(
            audioParts: [p1, p2, p3],
            transcriptText: "alpha\n\nbeta\n\ngamma",
            transcriptJSON: Self.fakeTranscriptJSON(text: "alpha\n\nbeta\n\ngamma"),
            outputRoot: output
        )

        // Folder named from the FIRST part's basename.
        #expect(folder.lastPathComponent == "2026.05.28 - 16.02 - BFTP call")

        // Every part landed under its original filename inside the folder.
        for part in [p1, p2, p3] {
            let landed = folder.appendingPathComponent(part.lastPathComponent)
            #expect(
                FileManager.default.fileExists(atPath: landed.path(percentEncoded: false)),
                "Part \(part.lastPathComponent) should be in the folder"
            )
        }

        // Transcript uses the first part's basename.
        let transcriptURL = folder.appendingPathComponent("2026.05.28 - 16.02 - BFTP call.txt")
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(transcript == "alpha\n\nbeta\n\ngamma")

        // Watch folder ends empty.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: watch.path(percentEncoded: false))
        #expect(leftovers.isEmpty, "Watch folder should be drained, has: \(leftovers)")
    }

    @Test
    func organize_singlePart_throughMultiPartAPI_matchesSingleAPI() async throws {
        let (watch, output) = try Self.makeWatchAndOutput()
        defer { Self.cleanUp(watch, output) }

        let only = try Self.putAudio(named: "solo.mp3", in: watch)
        let organizer = FileOrganizer()
        let folder = try await organizer.organize(
            audioParts: [only],
            transcriptText: "single",
            transcriptJSON: Self.fakeTranscriptJSON(text: "single"),
            outputRoot: output
        )

        #expect(folder.lastPathComponent == "solo")
        let landed = folder.appendingPathComponent("solo.mp3")
        #expect(FileManager.default.fileExists(atPath: landed.path(percentEncoded: false)))
        let transcript = try String(
            contentsOf: folder.appendingPathComponent("solo.txt"),
            encoding: .utf8
        )
        #expect(transcript == "single")
    }

    // MARK: - Validation

    @Test
    func organize_emptyParts_throwsAudioFileMissing() async throws {
        let (watch, output) = try Self.makeWatchAndOutput()
        defer { Self.cleanUp(watch, output) }

        let organizer = FileOrganizer()
        await #expect(throws: FileOrganizerError.self) {
            try await organizer.organize(
                audioParts: [],
                transcriptText: "x",
                transcriptJSON: Self.fakeTranscriptJSON(),
                outputRoot: output
            )
        }
    }

    @Test
    func organize_oneMissingPart_throwsAndLeavesOthersInPlace() async throws {
        let (watch, output) = try Self.makeWatchAndOutput()
        defer { Self.cleanUp(watch, output) }

        let real = try Self.putAudio(named: "real.mp3", in: watch)
        let ghost = watch.appendingPathComponent("ghost.mp3")  // never written

        let organizer = FileOrganizer()
        await #expect(throws: FileOrganizerError.self) {
            try await organizer.organize(
                audioParts: [real, ghost],
                transcriptText: "x",
                transcriptJSON: Self.fakeTranscriptJSON(),
                outputRoot: output
            )
        }

        // `real` should still be in the watch folder — the validation
        // failure means we never started moving.
        #expect(FileManager.default.fileExists(atPath: real.path(percentEncoded: false)))
        // Output should have no meeting folder for it either.
        let outContents = try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))
        #expect(outContents.isEmpty, "No folder should have been created, has: \(outContents)")
    }

    // MARK: - Rollback

    /// `FileManager` subclass that fails the Nth call to `moveItem` —
    /// lets us deterministically trip the rollback path inside
    /// `organize(audioParts:...)` without depending on filesystem races.
    private final class FailOnNthMove: FileManager, @unchecked Sendable {
        let failOnCall: Int
        var moveCalls = 0
        init(failOnCall: Int) {
            self.failOnCall = failOnCall
            super.init()
        }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            moveCalls += 1
            if moveCalls == failOnCall {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
            }
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }

    @Test
    func organize_secondMoveFails_rollsBackFirstPartAndCleansFolder() async throws {
        let (watch, output) = try Self.makeWatchAndOutput()
        defer { Self.cleanUp(watch, output) }

        let p1 = try Self.putAudio(named: "meeting.mp3", in: watch)
        let p2 = try Self.putAudio(named: "meeting (part 2).mp3", in: watch)

        let fm = FailOnNthMove(failOnCall: 2)
        let organizer = FileOrganizer(fileManager: fm)

        await #expect(throws: FileOrganizerError.self) {
            try await organizer.organize(
                audioParts: [p1, p2],
                transcriptText: "x",
                transcriptJSON: Self.fakeTranscriptJSON(),
                outputRoot: output
            )
        }

        // Both parts back in the watch folder — first one via rollback,
        // second one never moved.
        #expect(FileManager.default.fileExists(atPath: p1.path(percentEncoded: false)),
                "Rollback should restore p1")
        #expect(FileManager.default.fileExists(atPath: p2.path(percentEncoded: false)))

        // Output folder must be drained of the meeting folder.
        let outContents = try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))
        #expect(outContents.isEmpty, "Meeting folder should have been removed, has: \(outContents)")
    }
}
