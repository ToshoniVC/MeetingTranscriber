import Foundation

/// Non-persisted snapshot of everything `NotionClient` needs to call the
/// Notion REST API for a single meeting write. Assembled from `AppSettings`
/// at pipeline-start time, mirroring how `PipelineConfig` snapshots the
/// transcription settings — if the user flips a Notion setting mid-pipeline,
/// the coordinator restarts and produces a fresh config.
struct NotionConfig: Sendable, Equatable {

    /// Integration token (`secret_...`). Sent as `Authorization: Bearer ...`.
    /// Never logged.
    let token: String

    /// Notion database UUID. The value passed to the API is always the
    /// normalized 36-char hyphenated form (see `Self.normalize(databaseId:)`).
    let databaseId: String

    /// Notion API version header. Pinned to a known-good value rather than
    /// "the latest" so future Notion breaking changes don't silently
    /// affect us — we update this deliberately when we re-test.
    let apiVersion: String

    init(
        token: String,
        databaseId: String,
        apiVersion: String = NotionConfig.defaultAPIVersion
    ) {
        self.token = token
        self.databaseId = databaseId
        self.apiVersion = apiVersion
    }

    /// Default Notion API version. Documented at
    /// https://developers.notion.com/reference/versioning. Bump deliberately.
    static let defaultAPIVersion = "2022-06-28"

    /// Normalize a user-pasted database ID to the canonical 36-char
    /// `8-4-4-4-12` hyphenated UUID form Notion accepts in URLs. Returns
    /// nil if the input doesn't contain exactly 32 hex characters after
    /// stripping non-hex content. The caller is responsible for treating
    /// nil as "misconfigured".
    static func normalize(databaseId raw: String) -> String? {
        let hexOnly = raw.unicodeScalars.filter { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) || // 0-9
            (scalar.value >= 0x41 && scalar.value <= 0x46) || // A-F
            (scalar.value >= 0x61 && scalar.value <= 0x66)    // a-f
        }
        let hex = String(String.UnicodeScalarView(hexOnly)).lowercased()
        guard hex.count == 32 else { return nil }

        let chars = Array(hex)
        return "\(String(chars[0..<8]))-\(String(chars[8..<12]))-\(String(chars[12..<16]))-\(String(chars[16..<20]))-\(String(chars[20..<32]))"
    }
}
