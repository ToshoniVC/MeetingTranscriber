import Testing
import Foundation
@testable import Jot

/// Integration tests for the full `FolderWatcher` pipeline against a real
/// temporary directory. These tests *do* wait for short periods of wall
/// time (a couple of seconds each) because the watcher's stability rule is
/// inherently time-based — that's what the public contract guarantees.
struct FolderWatcherIntegrationTests {

    // MARK: - Helpers

    /// Make and return a fresh empty directory the test can fill with files.
    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-watcher-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Fresh ledger file URL that the test can clean up.
    private static func makeLedger() -> ProcessedFilesLedger {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-watcher-ledger-\(UUID().uuidString).json")
        return ProcessedFilesLedger(url: url)
    }

    /// Atomically writes `bytes` random data to `url`. Atomic so that the
    /// watcher never sees a half-written file (which is what we want for the
    /// "ready file" emit path — the debounce handles still-being-written
    /// files separately).
    private static func writeFile(_ url: URL, byteCount: Int) throws {
        let data = Data(repeating: 0xCC, count: byteCount)
        try data.write(to: url, options: [.atomic])
    }

    /// Read the next URL from the stream, with a wall-clock timeout.
    /// Returns `nil` if the stream ended or the timeout hit.
    private static func nextEvent(
        from stream: AsyncStream<URL>,
        timeout: TimeInterval
    ) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            group.addTask {
                for await url in stream { return url }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - Tests

    @Test
    func dropFile_emitsAfterStableDuration() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = try await FolderWatcher(
            folderURL: dir,
            stableDuration: 0.5,   // tighter than production for test speed
            recheckInterval: 0.25,
            ledger: Self.makeLedger()
        )
        let stream = try await watcher.start()
        defer { Task { await watcher.stop() } }

        let audio = dir.appendingPathComponent("meeting.mp3")
        try Self.writeFile(audio, byteCount: 4_096)

        let emitted = await Self.nextEvent(from: stream, timeout: 3.0)
        // Watcher emits symlink-resolved URLs (macOS `/var` → `/private/var`),
        // so compare resolved paths.
        #expect(emitted?.resolvingSymlinksInPath() == audio.resolvingSymlinksInPath())
    }

    @Test
    func hiddenFile_isIgnored() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = try await FolderWatcher(
            folderURL: dir,
            stableDuration: 0.3,
            recheckInterval: 0.2,
            ledger: Self.makeLedger()
        )
        let stream = try await watcher.start()
        defer { Task { await watcher.stop() } }

        try Self.writeFile(dir.appendingPathComponent(".secret.mp3"), byteCount: 1_024)

        let emitted = await Self.nextEvent(from: stream, timeout: 1.5)
        #expect(emitted == nil, "Hidden files should never be emitted")
    }

    @Test
    func unsupportedExtension_isIgnored() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = try await FolderWatcher(
            folderURL: dir,
            stableDuration: 0.3,
            recheckInterval: 0.2,
            ledger: Self.makeLedger()
        )
        let stream = try await watcher.start()
        defer { Task { await watcher.stop() } }

        try Self.writeFile(dir.appendingPathComponent("not-audio.txt"), byteCount: 1_024)

        let emitted = await Self.nextEvent(from: stream, timeout: 1.5)
        #expect(emitted == nil, ".txt files should never be emitted")
    }

    @Test
    func filesAlreadyInFolderAtStart_areEmittedAfterStableDuration() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // File exists *before* the watcher starts.
        let audio = dir.appendingPathComponent("preexisting.mp3")
        try Self.writeFile(audio, byteCount: 2_048)
        // Sleep a moment so its mtime is comfortably in the past.
        try await Task.sleep(nanoseconds: 100_000_000)

        let watcher = try await FolderWatcher(
            folderURL: dir,
            stableDuration: 0.3,
            recheckInterval: 0.2,
            ledger: Self.makeLedger()
        )
        let stream = try await watcher.start()
        defer { Task { await watcher.stop() } }

        let emitted = await Self.nextEvent(from: stream, timeout: 2.0)
        #expect(emitted?.resolvingSymlinksInPath() == audio.resolvingSymlinksInPath())
    }

    @Test
    func alreadyProcessedFile_isNotReemitted() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let audio = dir.appendingPathComponent("done.mp3")
        try Self.writeFile(audio, byteCount: 2_048)

        // Pre-seed the ledger so the watcher considers this file already
        // processed.
        let ledger = Self.makeLedger()
        try await ledger.record(audio)

        let watcher = try await FolderWatcher(
            folderURL: dir,
            stableDuration: 0.3,
            recheckInterval: 0.2,
            ledger: ledger
        )
        let stream = try await watcher.start()
        defer { Task { await watcher.stop() } }

        let emitted = await Self.nextEvent(from: stream, timeout: 1.5)
        #expect(emitted == nil)
    }

    @Test
    func startFailsOnMissingFolder() async {
        let nonexistent = URL(fileURLWithPath: "/Volumes/this-volume-does-not-exist/jot-test")
        do {
            _ = try await FolderWatcher(folderURL: nonexistent)
            Issue.record("Expected init to throw for missing folder")
        } catch let error as FolderWatcher.WatcherError {
            if case .folderDoesNotExist = error {
                // ok
            } else {
                Issue.record("Expected folderDoesNotExist, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
