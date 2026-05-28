import Testing
import Foundation
@testable import Jot

/// Tests for `AuditLogStore.updateNotionStatus(...)` — the in-place row
/// mutation the pipeline uses to flip `.pending` to `.succeeded` /
/// `.failed` once the async Notion write completes.
@MainActor
struct AuditLogStoreNotionTests {

    private func tmpStore() -> AuditLogStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-audit-notion-\(UUID().uuidString).json")
        return AuditLogStore(fileURL: url)
    }

    @Test
    func updateNotionStatus_replacesField_onMatchingEntry() {
        let store = tmpStore()
        let entry = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            notionStatus: .pending
        )
        store.append(entry)

        let url = URL(string: "https://www.notion.so/Page-abc")!
        store.updateNotionStatus(.succeeded(pageURL: url), forEntry: entry.id)

        #expect(store.entries.first?.notionStatus == .succeeded(pageURL: url))
        #expect(store.entries.first?.id == entry.id)
        #expect(store.entries.first?.message == "ok")
    }

    @Test
    func updateNotionStatus_isNoOp_whenEntryNotFound() {
        let store = tmpStore()
        let entry = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            notionStatus: .pending
        )
        store.append(entry)
        let bogusId = UUID()
        store.updateNotionStatus(.failed(message: "boom"), forEntry: bogusId)
        #expect(store.entries.first?.notionStatus == .pending)
    }

    @Test
    func updateNotionStatus_persistsToDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-audit-notion-\(UUID().uuidString).json")
        let store = AuditLogStore(fileURL: url)
        let entry = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            notionStatus: .pending
        )
        store.append(entry)
        let pageURL = URL(string: "https://www.notion.so/Page-abc")!
        store.updateNotionStatus(.succeeded(pageURL: pageURL), forEntry: entry.id)

        // Reload from disk into a fresh store; the update must have stuck.
        let reborn = AuditLogStore(fileURL: url)
        #expect(reborn.entries.first?.notionStatus == .succeeded(pageURL: pageURL))
    }

    @Test
    func markRetried_preservesNotionStatus() {
        let store = tmpStore()
        let failure = AuditLogEntry(
            kind: .failure,
            sourcePath: "/tmp/x.mp3",
            message: "boom",
            retryable: true,
            notionStatus: .skipped(reason: .disabled)
        )
        store.append(failure)
        store.markRetried(failure.id)
        #expect(store.entries.first?.notionStatus == .skipped(reason: .disabled))
        #expect(store.entries.first?.retryable == false)
    }
}
