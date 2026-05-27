import Testing
import Foundation
@testable import Jot

/// Tests for `AuditLogStore` — append, ordering, bounding at maxEntries,
/// clear, markRetried, and round-trip persistence across instances.
@MainActor
struct AuditLogStoreTests {

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-audit-log-test-\(UUID().uuidString).json")
    }

    // MARK: - Empty state

    @Test
    func newStore_isEmpty() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AuditLogStore(fileURL: url)
        #expect(store.entries.isEmpty)
    }

    // MARK: - Append + ordering

    @Test
    func append_putsNewestEntryFirst() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AuditLogStore(fileURL: url)

        let first = AuditLogEntry(kind: .info, sourcePath: "/a", message: "first")
        let second = AuditLogEntry(kind: .info, sourcePath: "/b", message: "second")
        store.append(first)
        store.append(second)

        #expect(store.entries.first?.message == "second")
        #expect(store.entries.last?.message == "first")
    }

    // MARK: - Bounding

    @Test
    func append_atCap_dropsOldestEntries() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AuditLogStore(fileURL: url, maxEntries: 3)

        for i in 0..<5 {
            store.append(AuditLogEntry(kind: .info, sourcePath: "/p", message: "e\(i)"))
        }

        #expect(store.entries.count == 3)
        // Newest first → e4, e3, e2 retained; e0 and e1 dropped.
        #expect(store.entries.map(\.message) == ["e4", "e3", "e2"])
    }

    // MARK: - Clear

    @Test
    func clear_emptiesTheStore() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AuditLogStore(fileURL: url)
        store.append(.init(kind: .info, sourcePath: "/a", message: "x"))
        store.append(.init(kind: .info, sourcePath: "/b", message: "y"))
        store.clear()
        #expect(store.entries.isEmpty)
    }

    // MARK: - markRetried

    @Test
    func markRetried_flipsRetryableFlag() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AuditLogStore(fileURL: url)
        let entry = AuditLogEntry(
            id: UUID(), kind: .failure,
            sourcePath: "/a", message: "boom", retryable: true
        )
        store.append(entry)
        #expect(store.entries.first?.retryable == true)
        store.markRetried(entry.id)
        #expect(store.entries.first?.retryable == false)
    }

    @Test
    func markRetried_unknownID_isNoOp() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AuditLogStore(fileURL: url)
        let entry = AuditLogEntry(kind: .info, sourcePath: "/a", message: "x")
        store.append(entry)
        store.markRetried(UUID())
        #expect(store.entries.first?.message == "x")
    }

    // MARK: - Persistence across instances

    @Test
    func entries_persistAcrossInstances() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = AuditLogStore(fileURL: url)
            store.append(.init(kind: .success, sourcePath: "/a", message: "ok"))
            store.append(.init(kind: .failure, sourcePath: "/b", message: "no", retryable: true))
        }
        let reborn = AuditLogStore(fileURL: url)
        #expect(reborn.entries.count == 2)
        // Newest-first ordering survives persistence.
        #expect(reborn.entries.first?.message == "no")
    }

    @Test
    func clear_persistsEmpty() {
        let url = Self.tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = AuditLogStore(fileURL: url)
            store.append(.init(kind: .info, sourcePath: "/a", message: "x"))
            store.clear()
        }
        let reborn = AuditLogStore(fileURL: url)
        #expect(reborn.entries.isEmpty)
    }
}
