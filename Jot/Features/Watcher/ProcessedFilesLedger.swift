import CryptoKit
import Foundation

/// On-disk record of files the watcher has already emitted to the pipeline.
/// Survives relaunches so a file that was processed yesterday isn't
/// re-processed today even though it's still sitting in the (deleted-from-
/// Audio-Hijack-but-not-yet-cleaned-up) Watch Folder.
///
/// Stored as a JSON dictionary keyed on the file's absolute path, with a
/// short SHA-256 prefix of its contents at processing time as the value
/// (so renamed-but-otherwise-identical files can be detected later, and so
/// a "same path, totally different file" can be re-processed if needed).
///
/// **Storage location:** `~/Library/Application Support/Jot/processed-files.json`
/// (or `Jot Dev/...` for the Debug variant — same per-bundle separation as
/// the rest of `AppSettings`).
actor ProcessedFilesLedger {

    private let url: URL
    private var entries: [String: String] = [:]   // absolutePath → sha256-prefix
    private var loaded = false

    /// - Parameter url: full file URL to persist to. Default points to
    ///   `Application Support/<AppName>/processed-files.json` and lazily
    ///   creates the parent directory.
    init(url: URL = ProcessedFilesLedger.defaultURL()) {
        self.url = url
    }

    /// Default storage URL: `Application Support/<bundleName>/processed-files.json`.
    /// Falls back to `~/Library/Application Support/Jot/...` if the bundle name
    /// can't be resolved (e.g., when running outside an app — shouldn't happen
    /// in practice but better than crashing).
    static func defaultURL() -> URL {
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
        return dir.appendingPathComponent("processed-files.json")
    }

    /// Whether the ledger already contains `url`. Loads lazily on first call.
    func contains(_ fileURL: URL) async -> Bool {
        await ensureLoaded()
        return entries[Self.normalize(fileURL)] != nil
    }

    /// Record that `fileURL` was processed. Idempotent — recording the same
    /// URL twice is a no-op (the second call just refreshes the hash if the
    /// contents changed).
    func record(_ fileURL: URL) async throws {
        await ensureLoaded()
        let hash = (try? Self.shortSHA256(of: fileURL)) ?? "<unreadable>"
        entries[Self.normalize(fileURL)] = hash
        try persist()
    }

    /// Remove `fileURL` from the ledger. Used when a file is deleted or
    /// renamed so the watcher can re-process if it reappears.
    func forget(_ fileURL: URL) async throws {
        await ensureLoaded()
        entries.removeValue(forKey: Self.normalize(fileURL))
        try persist()
    }

    /// Canonicalize the path used as the ledger key.
    ///
    /// macOS has `/var` as a symlink to `/private/var`, and other symlinks
    /// can show up depending on where the user pointed Audio Hijack. Without
    /// resolving them, the same file can appear under two different paths
    /// (the user-visible one vs. the one `FileManager` returns) and we'd
    /// fail to recognize that we already processed it.
    private static func normalize(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    /// Wipe the entire ledger. Tests use this; the app generally doesn't.
    func reset() async throws {
        await ensureLoaded()
        entries.removeAll()
        try persist()
    }

    /// Count of recorded entries — exposed for tests.
    func count() async -> Int {
        await ensureLoaded()
        return entries.count
    }

    // MARK: - Persistence

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true

        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = decoded
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: url, options: [.atomic])
    }

    /// Read the first 64 KiB of the file and return the first 16 hex chars of
    /// its SHA-256. We don't need a full-file content hash — this is a "did
    /// this file get replaced with completely different bytes?" signal, not
    /// a security primitive. 64 KiB is plenty for that.
    private static func shortSHA256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
        let digest = SHA256.hash(data: chunk)
        return digest.compactMap { String(format: "%02x", $0) }.prefix(16).joined()
    }
}
