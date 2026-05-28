import Testing
import Foundation
@testable import Jot

/// Tests for `AuditLogStore.updateClaudeCodeStatus(...)` — the in-place
/// row mutation the pipeline uses to surface the post-Notion routine
/// fire outcome (skipped / fired / failed).
@MainActor
struct AuditLogStoreClaudeCodeTests {

    private func tmpStore() -> AuditLogStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-audit-cc-\(UUID().uuidString).json")
        return AuditLogStore(fileURL: url)
    }

    @Test
    func updateClaudeCodeStatus_replacesField_onMatchingEntry() {
        let store = tmpStore()
        let entry = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok"
        )
        store.append(entry)

        store.updateClaudeCodeStatus(.fired, forEntry: entry.id)

        #expect(store.entries.first?.claudeCodeStatus == .fired)
        #expect(store.entries.first?.id == entry.id)
        #expect(store.entries.first?.message == "ok")
    }

    @Test
    func updateClaudeCodeStatus_isNoOp_whenEntryNotFound() {
        let store = tmpStore()
        let entry = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            claudeCodeStatus: .skipped(reason: .disabled)
        )
        store.append(entry)
        store.updateClaudeCodeStatus(.failed(message: "boom"), forEntry: UUID())
        #expect(store.entries.first?.claudeCodeStatus == .skipped(reason: .disabled))
    }

    @Test
    func updateClaudeCodeStatus_persistsToDisk() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-audit-cc-\(UUID().uuidString).json")
        let store = AuditLogStore(fileURL: url)
        let entry = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok"
        )
        store.append(entry)
        store.updateClaudeCodeStatus(.failed(message: "rejected"), forEntry: entry.id)

        let reborn = AuditLogStore(fileURL: url)
        #expect(reborn.entries.first?.claudeCodeStatus == .failed(message: "rejected"))
    }

    @Test
    func markRetried_preservesClaudeCodeStatus() {
        let store = tmpStore()
        let failure = AuditLogEntry(
            kind: .failure,
            sourcePath: "/tmp/x.mp3",
            message: "boom",
            retryable: true,
            claudeCodeStatus: .skipped(reason: .notionNotReady)
        )
        store.append(failure)
        store.markRetried(failure.id)
        #expect(store.entries.first?.claudeCodeStatus == .skipped(reason: .notionNotReady))
        #expect(store.entries.first?.retryable == false)
    }

    // MARK: - Codable round-trip

    @Test
    func claudeCodeStatus_codable_roundTripsAllCases() throws {
        let cases: [ClaudeCodeRoutineStatus] = [
            .skipped(reason: .disabled),
            .skipped(reason: .misconfigured),
            .skipped(reason: .notionNotReady),
            .fired,
            .failed(message: "unauthorized")
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for original in cases {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ClaudeCodeRoutineStatus.self, from: data)
            #expect(decoded == original)
        }
    }
}
