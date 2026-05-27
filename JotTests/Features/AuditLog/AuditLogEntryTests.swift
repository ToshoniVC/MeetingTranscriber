import Testing
import Foundation
@testable import Jot

/// Codable round-trip + default-value tests for `AuditLogEntry`. The audit
/// log file persists as JSON of an array of these, so the contract matters.
struct AuditLogEntryTests {

    @Test
    func defaults_areReasonable() {
        let entry = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/meeting.mp3",
            message: "ok"
        )
        #expect(entry.durationMs == nil)
        #expect(entry.retryable == false)
        // id and timestamp are auto-generated but should not be empty / epoch
        #expect(entry.timestamp.timeIntervalSince1970 > 1_000_000_000)
    }

    @Test
    func codable_roundTripPreservesAllFields() throws {
        let original = AuditLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 100_000),
            kind: .failure,
            sourcePath: "/tmp/x.mp3",
            message: "API key was rejected",
            durationMs: 2_345,
            retryable: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func codable_arrayRoundTrip() throws {
        let entries: [AuditLogEntry] = [
            .init(kind: .info, sourcePath: "/a", message: "started"),
            .init(kind: .success, sourcePath: "/b", message: "done", durationMs: 100),
            .init(kind: .failure, sourcePath: "/c", message: "fail", retryable: true),
        ]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([AuditLogEntry].self, from: data)
        #expect(decoded == entries)
    }
}
