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

    // MARK: - Schema v2 (Phase G)

    @Test
    func newEntry_defaultsToSchemaV2() {
        let entry = AuditLogEntry(kind: .info, sourcePath: "/a", message: "x")
        #expect(entry.schemaVersion == 2)
        #expect(entry.contextAttached == nil)
        #expect(entry.organizationName == nil)
    }

    @Test
    func roundTrip_preservesNewSchemaV2Fields() throws {
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            durationMs: 1234,
            retryable: false,
            contextAttached: true,
            organizationName: "Acme"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.contextAttached == true)
        #expect(decoded.organizationName == "Acme")
    }

    /// A legacy v1 JSON payload (no schemaVersion / contextAttached /
    /// organizationName keys) decodes cleanly with schemaVersion=1 and
    /// the new fields defaulted to nil.
    @Test
    func decode_legacyV1Payload_setsSchema1AndNilFields() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "timestamp": 1700000000.0,
            "kind": "success",
            "sourcePath": "/tmp/legacy.mp3",
            "message": "old success",
            "durationMs": 500,
            "retryable": false
        }
        """
        let decoded = try JSONDecoder().decode(
            AuditLogEntry.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.message == "old success")
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.contextAttached == nil)
        #expect(decoded.organizationName == nil)
    }

    @Test
    func decode_legacyV1_missingRetryable_defaultsToFalse() throws {
        // Even older payload without retryable — should default cleanly.
        let legacyJSON = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "timestamp": 1700000000.0,
            "kind": "info",
            "sourcePath": "/tmp/x",
            "message": "hello"
        }
        """
        let decoded = try JSONDecoder().decode(
            AuditLogEntry.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.retryable == false)
        #expect(decoded.schemaVersion == 1)
    }
}
