import Testing
import Foundation
@testable import Jot

/// Tests for `ProcessingPipeline.folderTimestamp(for:)` — the date format
/// that prefixes meeting folder names so they sort chronologically.
struct MeetingFolderTimestampTests {

    @Test
    func format_isYearMonthDayHourMinute() {
        // 2026-05-28 14:23:45 local time → "2026.05.28 - 14.23"
        var components = DateComponents()
        components.timeZone = .current
        components.year = 2026
        components.month = 5
        components.day = 28
        components.hour = 14
        components.minute = 23
        components.second = 45
        let date = Calendar.current.date(from: components)!
        #expect(ProcessingPipeline.folderTimestamp(for: date) == "2026.05.28 - 14.23")
    }

    @Test
    func format_padsSingleDigits() {
        var components = DateComponents()
        components.timeZone = .current
        components.year = 2026
        components.month = 1
        components.day = 3
        components.hour = 7
        components.minute = 5
        let date = Calendar.current.date(from: components)!
        #expect(ProcessingPipeline.folderTimestamp(for: date) == "2026.01.03 - 07.05")
    }

    @Test
    func format_uses24HourClock() {
        // 23:59 should render as 23.59, not 11.59 PM or similar.
        var components = DateComponents()
        components.timeZone = .current
        components.year = 2026
        components.month = 12
        components.day = 31
        components.hour = 23
        components.minute = 59
        let date = Calendar.current.date(from: components)!
        #expect(ProcessingPipeline.folderTimestamp(for: date) == "2026.12.31 - 23.59")
    }
}

/// Tests for `ProcessingPipeline.relocateMissingFile(...)` — the v0.4.7
/// recovery helper that finds a recording's audio file when Audio Hijack
/// renamed it between the watcher emit and our processing. Kept in the
/// same test file as the other static-helper tests so it doesn't need
/// a fresh pbxproj wiring.
struct RelocateMissingFileTests {

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-relocate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a file with a specific creation date by writing data then
    /// setting `creationDate` via `URLResourceValues`. macOS honours the
    /// override, so we get a hermetic "this file was created at T" fixture.
    private static func putAudio(
        at url: URL,
        creationDate: Date
    ) throws {
        try Data("x".utf8).write(to: url)
        var resourceValues = URLResourceValues()
        resourceValues.creationDate = creationDate
        var mutable = url
        try mutable.setResourceValues(resourceValues)
    }

    // MARK: - Happy paths

    @Test
    func fileStillThere_returnsOriginalURL() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("recording.mp3")
        try Self.putAudio(at: url, creationDate: Date())

        let resolved = ProcessingPipeline.relocateMissingFile(
            url: url, expectedCreationDate: Date()
        )
        #expect(resolved == url)
    }

    @Test
    func missingFile_singleNearbyMatch_isReturned() throws {
        // Simulates Audio Hijack renaming `recording.mp3` to
        // `recording-end-2013.mp3` after our watcher emitted the URL.
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let startedAt = Date()
        let staleURL = dir.appendingPathComponent("recording.mp3")
        let renamedURL = dir.appendingPathComponent("recording-end-2013.mp3")
        try Self.putAudio(at: renamedURL, creationDate: startedAt.addingTimeInterval(0.5))

        let resolved = ProcessingPipeline.relocateMissingFile(
            url: staleURL, expectedCreationDate: startedAt
        )
        #expect(resolved == renamedURL)
    }

    @Test
    func missingFile_multipleCandidates_returnsNil() throws {
        // Ambiguous — two files match the anchor within slop. We refuse
        // to guess; caller will surface the original "file not found"
        // with the parent directory listing.
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let startedAt = Date()
        try Self.putAudio(
            at: dir.appendingPathComponent("recording-a.mp3"),
            creationDate: startedAt.addingTimeInterval(1)
        )
        try Self.putAudio(
            at: dir.appendingPathComponent("recording-b.mp3"),
            creationDate: startedAt.addingTimeInterval(2)
        )

        let resolved = ProcessingPipeline.relocateMissingFile(
            url: dir.appendingPathComponent("ghost.mp3"),
            expectedCreationDate: startedAt
        )
        #expect(resolved == nil)
    }

    @Test
    func missingFile_noNearbyAudio_returnsNil() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not audio".utf8).write(
            to: dir.appendingPathComponent("README.txt")
        )

        let resolved = ProcessingPipeline.relocateMissingFile(
            url: dir.appendingPathComponent("ghost.mp3"),
            expectedCreationDate: Date()
        )
        #expect(resolved == nil)
    }

    @Test
    func missingFile_outsideSlopWindow_returnsNil() throws {
        // An audio file exists in the dir but its creation date is way
        // off from what we expect — probably last week's meeting, not
        // ours. Refuse the match.
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let startedAt = Date()
        try Self.putAudio(
            at: dir.appendingPathComponent("yesterday.mp3"),
            creationDate: startedAt.addingTimeInterval(-86_400)
        )

        let resolved = ProcessingPipeline.relocateMissingFile(
            url: dir.appendingPathComponent("ghost.mp3"),
            expectedCreationDate: startedAt,
            slop: 30
        )
        #expect(resolved == nil)
    }

    @Test
    func missingFile_acceptsM4AAndWAV() throws {
        // Same behaviour for m4a and wav: extension is part of the
        // candidate filter so non-audio noise in the watch folder
        // doesn't confuse the match.
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let startedAt = Date()
        let m4a = dir.appendingPathComponent("recording-end.m4a")
        try Self.putAudio(at: m4a, creationDate: startedAt)

        let resolved = ProcessingPipeline.relocateMissingFile(
            url: dir.appendingPathComponent("recording.m4a"),
            expectedCreationDate: startedAt
        )
        #expect(resolved == m4a)
    }
}

