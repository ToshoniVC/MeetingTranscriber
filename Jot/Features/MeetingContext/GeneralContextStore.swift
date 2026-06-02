import Foundation
import Observation

/// Persistent store for the single `GeneralContext` record backing the
/// Context tab's "General" entry.
///
/// Mirrors `OrganizationStore`: `@MainActor` + `@Observable` so SwiftUI binds
/// directly; load on init; persist atomically on every mutation; per-bundle
/// storage so Jot and Jot Dev keep independent profiles.
///
/// **Storage location:** `Application Support/<bundleName>/general-context.json`.
///
/// Unlike `OrganizationStore` there is no collection — exactly one record,
/// exposed as `current`. A missing or unreadable file yields the default
/// (`GeneralContext()`), which carries the default wrapper prefix.
@MainActor
@Observable
final class GeneralContextStore {

    /// The current record. SwiftUI binds to this directly.
    private(set) var current: GeneralContext

    private let fileURL: URL

    init(fileURL: URL = GeneralContextStore.defaultURL()) {
        self.fileURL = fileURL
        self.current = GeneralContextStore.loaded(from: fileURL) ?? GeneralContext()
    }

    // MARK: - Public API

    /// Update one or both fields and persist. Passing `nil` leaves that field
    /// untouched, so the two editor bindings can commit independently.
    func update(wrapperPrefix: String? = nil, generalContext: String? = nil) {
        var next = current
        if let wrapperPrefix { next.wrapperPrefix = wrapperPrefix }
        if let generalContext { next.generalContext = generalContext }
        next.updatedAt = Date()
        current = next
        persist()
    }

    // MARK: - Storage

    /// Default storage URL: `Application Support/<bundleName>/general-context.json`.
    /// Nonisolated so it works as an `init` default value.
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
        return dir.appendingPathComponent("general-context.json")
    }

    private nonisolated static func loaded(from fileURL: URL) -> GeneralContext? {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(GeneralContext.self, from: data)
        else { return nil }
        return decoded
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(current)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Log.pipeline.error(
                "GeneralContextStore persist failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
