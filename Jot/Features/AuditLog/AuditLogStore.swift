import Foundation
import Observation

/// Persistent in-memory store of `AuditLogEntry` records, with a JSON file
/// for cross-launch durability.
///
/// **@Observable + @MainActor.** The Audit Log tab binds directly to
/// `entries`, so the store lives on the main actor and SwiftUI re-renders
/// when entries change. Pipeline calls into it via `await` (the pipeline is
/// an actor, hops to main here).
///
/// **Bounded to 1000 entries.** When the cap is reached, oldest entries are
/// dropped on append. This protects the JSON file from runaway growth on a
/// long-running install.
///
/// **Storage location:** `Application Support/<bundleName>/audit-log.json`
/// — same per-bundle separation as `AppSettings` (Jot vs Jot Dev get
/// separate logs).
@MainActor
@Observable
final class AuditLogStore {

    /// Newest-first list of entries. SwiftUI binds to this directly.
    private(set) var entries: [AuditLogEntry] = []

    /// Maximum entries retained on disk + in memory. Beyond this, oldest are
    /// dropped on append.
    let maxEntries: Int

    private let fileURL: URL
    private var loaded = false

    init(
        fileURL: URL = AuditLogStore.defaultURL(),
        maxEntries: Int = 1_000
    ) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
        load()
    }

    // MARK: - Mutations

    /// Append a single entry. The store enforces the `maxEntries` cap by
    /// dropping the oldest entries when full. Persists to disk.
    func append(_ entry: AuditLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        persist()
    }

    /// Wipe the entire log. Backs the "Clear Log" button in `AuditLogView`.
    func clear() {
        entries.removeAll()
        persist()
    }

    /// Mark the failure entry with `id` as no-longer-retryable. Called by
    /// the Pipeline when a retry succeeds, so the Retry button disappears.
    func markRetried(_ id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let original = entries[idx]
        entries[idx] = AuditLogEntry(
            id: original.id,
            timestamp: original.timestamp,
            kind: original.kind,
            sourcePath: original.sourcePath,
            message: original.message,
            durationMs: original.durationMs,
            retryable: false,
            contextAttached: original.contextAttached,
            organizationName: original.organizationName
        )
        persist()
    }

    // MARK: - Storage

    /// Default storage URL: `Application Support/<bundleName>/audit-log.json`.
    /// Nonisolated so it can be used as a default value in `init`.
    nonisolated static func defaultURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Jot"
        let dir = support.appendingPathComponent(appName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit-log.json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AuditLogEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Log.pipeline.error("AuditLogStore persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
