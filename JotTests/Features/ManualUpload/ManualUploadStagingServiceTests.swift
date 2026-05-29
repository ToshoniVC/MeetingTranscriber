import Testing
import Foundation
@testable import Jot

/// Unit tests for `ManualUploadStagingService`. Covers extension
/// validation (mp3 / mp4 / unsupported), existence + readability gates,
/// the copy-into-Watch-Folder semantics, and the collision-suffix path
/// shared with `FileOrganizer.uniqueFolderURL`.
struct ManualUploadStagingServiceTests {

    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-upload-\(UUID().uuidString)")
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

    // MARK: - validate

    @Test
    func validate_mp3_returnsAudioKind() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let url = try Self.putFile(named: "clip.mp3", in: dir)
        let service = ManualUploadStagingService()

        let kind = try service.validate(url)
        #expect(kind == .audio)
    }

    @Test
    func validate_mp4_returnsVideoKind() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let url = try Self.putFile(named: "clip.mp4", in: dir)
        let service = ManualUploadStagingService()

        let kind = try service.validate(url)
        #expect(kind == .videoMP4)
    }

    @Test
    func validate_uppercaseExtension_isAccepted() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let url = try Self.putFile(named: "CLIP.MP3", in: dir)
        let service = ManualUploadStagingService()

        let kind = try service.validate(url)
        #expect(kind == .audio)
    }

    // MARK: - v0.5.3 extra audio formats

    @Test
    func validate_m4a_returnsAudioKind() throws {
        // m4a was rejected before v0.5.3 — added so users can upload
        // afconvert-normalized files when Whisper rejects a raw MP3.
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let url = try Self.putFile(named: "recording.m4a", in: dir)
        let service = ManualUploadStagingService()

        let kind = try service.validate(url)
        #expect(kind == .audio)
    }

    @Test
    func validate_wav_returnsAudioKind() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let url = try Self.putFile(named: "recording.wav", in: dir)
        let service = ManualUploadStagingService()

        let kind = try service.validate(url)
        #expect(kind == .audio)
    }

    @Test
    func validate_unsupportedExtension_throws() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let url = try Self.putFile(named: "clip.aif", in: dir)
        let service = ManualUploadStagingService()

        #expect(throws: ManualUploadError.unsupportedFormat("aif")) {
            _ = try service.validate(url)
        }
    }

    @Test
    func validate_missingFile_throws() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let url = dir.appendingPathComponent("ghost.mp3")
        let service = ManualUploadStagingService()

        #expect(throws: ManualUploadError.fileNotFound(url)) {
            _ = try service.validate(url)
        }
    }

    // MARK: - stage

    @Test
    func stage_copiesIntoWatchFolderPreservingName() throws {
        let dir = try Self.makeTempDir()
        let watch = try Self.makeTempDir()
        defer { Self.cleanUp(dir, watch) }
        let source = try Self.putFile(named: "Standup.mp3", in: dir, bytes: 128)
        let service = ManualUploadStagingService()

        let target = try service.stage(source: source, into: watch)

        #expect(target.lastPathComponent == "Standup.mp3")
        #expect(FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        // Source must remain in place — we copied, not moved.
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test
    func stage_collidingName_appendsSuffix2() throws {
        let dir = try Self.makeTempDir()
        let watch = try Self.makeTempDir()
        defer { Self.cleanUp(dir, watch) }
        // Pre-occupy `Standup.mp3` so the staging path has to walk.
        _ = try Self.putFile(named: "Standup.mp3", in: watch)
        let source = try Self.putFile(named: "Standup.mp3", in: dir, bytes: 128)
        let service = ManualUploadStagingService()

        let target = try service.stage(source: source, into: watch)

        #expect(target.lastPathComponent == "Standup-2.mp3")
    }

    @Test
    func stage_missingWatchFolder_throwsUnreachable() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let source = try Self.putFile(named: "clip.mp3", in: dir)
        let bogusWatch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-not-a-folder-\(UUID().uuidString)")
        let service = ManualUploadStagingService()

        #expect(throws: ManualUploadError.watchFolderUnreachable) {
            _ = try service.stage(source: source, into: bogusWatch)
        }
    }

    @Test
    func uniqueURL_freshFolder_returnsDirectName() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let service = ManualUploadStagingService()

        let url = service.uniqueURL(under: dir, baseName: "clip", ext: "mp3")
        #expect(url.lastPathComponent == "clip.mp3")
    }
}
