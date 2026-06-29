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

    // MARK: - Schema v7 (Notion-only retry payload)

    @Test
    func newEntry_defaultsToCurrentSchema() {
        let entry = AuditLogEntry(kind: .info, sourcePath: "/a", message: "x")
        #expect(entry.schemaVersion == 7)
        #expect(entry.contextAttached == nil)
        #expect(entry.organizationName == nil)
        #expect(entry.notionStatus == nil)
        #expect(entry.claudeCodeStatus == nil)
        #expect(entry.transcriptionProvider == nil)
        #expect(entry.batchPartPaths == nil)
        #expect(entry.retryMeetingName == nil)
        #expect(entry.retryCompiledContext == nil)
        #expect(entry.recordingStartedAt == nil)
        #expect(entry.meetingFolderPath == nil)
    }

    @Test
    func roundTrip_preservesMeetingFolderPath() throws {
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "Transcribed",
            notionStatus: .failed(message: "HTTP 400"),
            retryMeetingName: "Weekly Sync",
            retryCompiledContext: "Org: Acme",
            meetingFolderPath: "/Output/Weekly Sync"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
        #expect(decoded.meetingFolderPath == "/Output/Weekly Sync")
        #expect(decoded.retryMeetingName == "Weekly Sync")
    }

    /// A schema-6 JSON payload (batch-retry fields but no `meetingFolderPath`)
    /// decodes cleanly with the new field nil — the migration contract for
    /// logs written before Notion-only retry.
    @Test
    func decode_legacyV6Payload_leavesMeetingFolderPathNil() throws {
        let legacyJSON = """
        {
            "id": "66666666-6666-6666-6666-666666666666",
            "timestamp": 1700000000.0,
            "kind": "success",
            "sourcePath": "/tmp/legacy.mp3",
            "message": "v6 success",
            "retryable": false,
            "schemaVersion": 6
        }
        """
        let decoded = try JSONDecoder().decode(
            AuditLogEntry.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.schemaVersion == 6)
        #expect(decoded.meetingFolderPath == nil)
    }

    @Test
    func withNotionStatus_preservesMeetingFolderPath() {
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            notionStatus: .pending,
            meetingFolderPath: "/Output/Meeting"
        )
        let updated = original.withNotionStatus(.failed(message: "boom"))
        #expect(updated.meetingFolderPath == "/Output/Meeting")
        #expect(updated.notionStatus == .failed(message: "boom"))
    }

    @Test
    func roundTrip_preservesBatchRetryPayload() throws {
        let original = AuditLogEntry(
            kind: .failure,
            sourcePath: "/tmp/part1.mp3",
            message: "All providers failed",
            retryable: true,
            contextAttached: true,
            organizationName: "Acme",
            batchPartPaths: ["/tmp/part1.mp3", "/tmp/part2.mp3", "/tmp/part3.mp3"],
            retryMeetingName: "Quarterly Review",
            retryCompiledContext: "Org: Acme. Attendees: …",
            recordingStartedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
        #expect(decoded.batchPartPaths?.count == 3)
        #expect(decoded.retryMeetingName == "Quarterly Review")
        #expect(decoded.retryCompiledContext == "Org: Acme. Attendees: …")
        #expect(decoded.recordingStartedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A schema-5 JSON payload (transcriptionProvider but no batch-retry
    /// fields) decodes cleanly with the batch fields nil — the migration
    /// contract for logs written before this feature.
    @Test
    func decode_legacyV5Payload_leavesBatchFieldsNil() throws {
        let legacyJSON = """
        {
            "id": "55555555-5555-5555-5555-555555555555",
            "timestamp": 1700000000.0,
            "kind": "success",
            "sourcePath": "/tmp/legacy.mp3",
            "message": "v5 success",
            "durationMs": 500,
            "retryable": false,
            "contextAttached": true,
            "organizationName": "Acme",
            "transcriptionProvider": "OpenAI",
            "schemaVersion": 5
        }
        """
        let decoded = try JSONDecoder().decode(
            AuditLogEntry.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.schemaVersion == 5)
        #expect(decoded.transcriptionProvider == "OpenAI")
        #expect(decoded.batchPartPaths == nil)
        #expect(decoded.retryMeetingName == nil)
        #expect(decoded.retryCompiledContext == nil)
        #expect(decoded.recordingStartedAt == nil)
    }

    @Test
    func withRetryable_preservesAllFields_includingBatchPayload() {
        let original = AuditLogEntry(
            kind: .failure,
            sourcePath: "/tmp/part1.mp3",
            message: "fail",
            retryable: true,
            organizationName: "Acme",
            transcriptionProvider: "Groq",
            batchPartPaths: ["/tmp/part1.mp3", "/tmp/part2.mp3"],
            retryMeetingName: "Standup",
            retryCompiledContext: "ctx",
            recordingStartedAt: Date(timeIntervalSince1970: 42)
        )
        let retired = original.withRetryable(false)
        #expect(retired.retryable == false)
        #expect(retired.id == original.id)
        #expect(retired.transcriptionProvider == "Groq")
        #expect(retired.batchPartPaths == original.batchPartPaths)
        #expect(retired.retryMeetingName == "Standup")
        #expect(retired.retryCompiledContext == "ctx")
        #expect(retired.recordingStartedAt == original.recordingStartedAt)
        #expect(retired.schemaVersion == original.schemaVersion)
    }

    @Test
    func roundTrip_preservesAddContextV2Fields_onCurrentSchemaEntry() throws {
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
        #expect(decoded.schemaVersion == 7)
        #expect(decoded.contextAttached == true)
        #expect(decoded.organizationName == "Acme")
    }

    @Test
    func roundTrip_preservesTranscriptionProvider() throws {
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "Transcribed via OpenAI → meeting",
            transcriptionProvider: "OpenAI"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
        #expect(decoded.transcriptionProvider == "OpenAI")
    }

    // MARK: - Schema v4 (claudeCodeStatus)

    @Test
    func roundTrip_preservesClaudeCodeStatus_fired() throws {
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            claudeCodeStatus: .fired
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func roundTrip_preservesClaudeCodeStatus_failed() throws {
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            claudeCodeStatus: .failed(message: "Claude Code rejected the request: invalid token")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func roundTrip_preservesClaudeCodeStatus_skipped_allReasons() throws {
        for reason in [
            ClaudeCodeRoutineStatus.SkipReason.disabled,
            .misconfigured,
            .notionNotReady
        ] {
            let original = AuditLogEntry(
                kind: .success,
                sourcePath: "/tmp/x.mp3",
                message: "ok",
                claudeCodeStatus: .skipped(reason: reason)
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
            #expect(decoded == original)
        }
    }

    /// A v3 JSON payload (with notionStatus but no claudeCodeStatus)
    /// decodes cleanly with claudeCodeStatus = nil.
    @Test
    func decode_legacyV3Payload_leavesClaudeCodeStatusNil() throws {
        let legacyJSON = """
        {
            "id": "44444444-4444-4444-4444-444444444444",
            "timestamp": 1700000000.0,
            "kind": "success",
            "sourcePath": "/tmp/legacy.mp3",
            "message": "v3 success",
            "durationMs": 500,
            "retryable": false,
            "contextAttached": true,
            "organizationName": "Acme",
            "notionStatus": {"kind": "pending"},
            "schemaVersion": 3
        }
        """
        let decoded = try JSONDecoder().decode(
            AuditLogEntry.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.notionStatus == .pending)
        #expect(decoded.claudeCodeStatus == nil)
    }

    @Test
    func roundTrip_preservesNotionStatus_success() throws {
        let url = URL(string: "https://www.notion.so/Page-abc")!
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            durationMs: 100,
            notionStatus: .succeeded(pageURL: url)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
        if case .succeeded(let decodedURL) = decoded.notionStatus {
            #expect(decodedURL == url)
        } else {
            Issue.record("Expected .succeeded, got \(String(describing: decoded.notionStatus))")
        }
    }

    @Test
    func roundTrip_preservesNotionStatus_skippedDisabled() throws {
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            notionStatus: .skipped(reason: .disabled)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func roundTrip_preservesNotionStatus_failed() throws {
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            notionStatus: .failed(message: "Notion rate-limited the request.")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func roundTrip_preservesNotionStatus_pending() throws {
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            notionStatus: .pending
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuditLogEntry.self, from: data)
        #expect(decoded == original)
    }

    /// A schema-2 JSON payload (with contextAttached + organizationName
    /// but no notionStatus) decodes cleanly, with notionStatus nil.
    @Test
    func decode_legacyV2Payload_setsSchema2AndNilNotionStatus() throws {
        let legacyJSON = """
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "timestamp": 1700000000.0,
            "kind": "success",
            "sourcePath": "/tmp/legacy.mp3",
            "message": "v2 success",
            "durationMs": 500,
            "retryable": false,
            "contextAttached": true,
            "organizationName": "Acme",
            "schemaVersion": 2
        }
        """
        let decoded = try JSONDecoder().decode(
            AuditLogEntry.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.message == "v2 success")
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.contextAttached == true)
        #expect(decoded.organizationName == "Acme")
        #expect(decoded.notionStatus == nil)
    }

    @Test
    func withNotionStatus_returnsCopyWithReplacedStatus() {
        let original = AuditLogEntry(
            kind: .success,
            sourcePath: "/tmp/x.mp3",
            message: "ok",
            notionStatus: .pending
        )
        let url = URL(string: "https://www.notion.so/Page-xyz")!
        let updated = original.withNotionStatus(.succeeded(pageURL: url))
        #expect(updated.id == original.id)
        #expect(updated.timestamp == original.timestamp)
        #expect(updated.message == original.message)
        #expect(updated.notionStatus == .succeeded(pageURL: url))
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
