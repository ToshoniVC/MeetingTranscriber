import Testing
import Foundation
@testable import Jot

/// Pure-logic unit tests for `FileOrganizer.uniqueFolderURL(...)`. Each test
/// uses a fresh tmpdir so naming is hermetic.
struct FileOrganizerUniqueNamingTests {

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-organize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func freshOutputFolder_returnsDirectName() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let organizer = FileOrganizer()
        let url = organizer.uniqueFolderURL(under: dir, baseName: "meeting")
        #expect(url.lastPathComponent == "meeting")
    }

    @Test
    func oneCollision_returnsSuffix2() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("meeting"),
            withIntermediateDirectories: false
        )
        let organizer = FileOrganizer()
        let url = organizer.uniqueFolderURL(under: dir, baseName: "meeting")
        #expect(url.lastPathComponent == "meeting-2")
    }

    @Test
    func multipleCollisions_walkSequentially() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["meeting", "meeting-2", "meeting-3"] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(name),
                withIntermediateDirectories: false
            )
        }
        let organizer = FileOrganizer()
        let url = organizer.uniqueFolderURL(under: dir, baseName: "meeting")
        #expect(url.lastPathComponent == "meeting-4")
    }
}
