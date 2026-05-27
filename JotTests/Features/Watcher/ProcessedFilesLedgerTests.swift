import Testing
import Foundation
@testable import Jot

/// Combined unit + integration coverage for the ledger. The persistence layer
/// (JSON to disk) is genuinely the unit's main responsibility, so most tests
/// exercise that round-trip.
struct ProcessedFilesLedgerTests {

    // MARK: - Helpers

    /// Returns a fresh ledger pointed at a temp file, plus the temp file URL
    /// so the test can clean up.
    private static func makeLedger() -> (ledger: ProcessedFilesLedger, fileURL: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-ledger-test-\(UUID().uuidString).json")
        return (ProcessedFilesLedger(url: url), url)
    }

    /// Write a small dummy file the ledger can read to compute its hash.
    private static func makeAudioFile(content: String = "fake audio") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-fake-audio-\(UUID().uuidString).mp3")
        try? content.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Empty state

    @Test
    func newLedger_isEmpty() async {
        let (ledger, file) = Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: file) }

        let count = await ledger.count()
        #expect(count == 0)
    }

    @Test
    func contains_unknownURL_returnsFalse() async {
        let (ledger, file) = Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: file) }

        let unknown = URL(fileURLWithPath: "/never/processed.mp3")
        let result = await ledger.contains(unknown)
        #expect(result == false)
    }

    // MARK: - Record + contains

    @Test
    func record_thenContains_returnsTrue() async throws {
        let (ledger, file) = Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await ledger.record(audio)
        let isRecorded = await ledger.contains(audio)
        #expect(isRecorded == true)
    }

    @Test
    func record_isIdempotent() async throws {
        let (ledger, file) = Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await ledger.record(audio)
        try await ledger.record(audio)
        try await ledger.record(audio)

        let count = await ledger.count()
        #expect(count == 1)
    }

    // MARK: - Persistence across instances

    @Test
    func recordedEntry_persists_acrossInstances() async throws {
        let (ledger, file) = Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await ledger.record(audio)

        // New ledger pointed at the same file == "restart".
        let reborn = ProcessedFilesLedger(url: file)
        let isRecorded = await reborn.contains(audio)
        #expect(isRecorded == true)
    }

    // MARK: - Forget

    @Test
    func forget_removesEntry() async throws {
        let (ledger, file) = Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await ledger.record(audio)
        try await ledger.forget(audio)

        let isRecorded = await ledger.contains(audio)
        #expect(isRecorded == false)
    }

    // MARK: - Reset

    @Test
    func reset_clearsAndPersistsEmpty() async throws {
        let (ledger, file) = Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await ledger.record(audio)
        try await ledger.reset()

        let count = await ledger.count()
        #expect(count == 0)

        let reborn = ProcessedFilesLedger(url: file)
        let rebornCount = await reborn.count()
        #expect(rebornCount == 0)
    }

    // MARK: - Hash robustness

    @Test
    func record_unreadableFile_doesNotThrow() async throws {
        let (ledger, file) = Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: file) }

        // File that doesn't exist — short-hash code returns sentinel, record still succeeds.
        let missing = URL(fileURLWithPath: "/never/created/\(UUID().uuidString).mp3")
        try await ledger.record(missing)
        let isRecorded = await ledger.contains(missing)
        #expect(isRecorded == true)
    }
}
