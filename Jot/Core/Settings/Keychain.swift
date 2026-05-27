import Foundation

/// Protocol abstracting persistent secret storage so tests can substitute an
/// in-memory fake (`InMemoryKeychain` in `JotTests/Helpers/`). The production
/// type `Keychain` below implements it via a JSON file in Application Support
/// — see the note on `Keychain` below for why we don't use the macOS Keychain
/// directly.
///
/// Per Claude/coding-instructions.md §3 (Secrets), the API key never lives in
/// `UserDefaults`, on disk in plaintext that's world-readable, or in git.
protocol KeychainStorage: Sendable {
    func setString(_ value: String, forKey key: String) throws
    func getString(forKey key: String) -> String?
    func deleteString(forKey key: String) throws
}

/// Errors thrown by the production `Keychain`.
enum KeychainError: Error, Equatable {
    case ioFailure(String)
    case unexpectedData
}

/// File-backed secret storage for the ad-hoc-signing free-path setup.
///
/// **Why not the real macOS Keychain?**
/// Every rebuild of an ad-hoc-signed binary produces a new code signature.
/// The macOS Keychain ties stored items to a specific code signature via its
/// ACL — so when the signature changes, every read prompts the user for
/// their login password ("Jot wants to access your Keychain"). For someone
/// iterating on the app this is roughly once-per-build, which is unworkable.
///
/// The file-backed approach skips that ACL entirely. The secret lives in a
/// JSON file with permissions `0600` (user-only read/write) inside the app's
/// Application Support directory, which is itself only accessible by
/// processes running as this user. For a single-user personal utility with
/// no shared multi-tenancy, this is an appropriate protection level — the
/// adversary it doesn't defend against (another process running as the same
/// user reading the file) would also be able to attach a debugger to a
/// running Jot process and read the key from memory anyway, so the macOS
/// Keychain wouldn't have helped against that threat either.
///
/// **Migration back to the real Keychain.** Once a Developer ID is added
/// (development-lifecycle.md §4.5), the code signature becomes stable across
/// rebuilds and the Keychain ACL stops misbehaving. The `KeychainStorage`
/// protocol surface stays the same; this struct's body would be replaced
/// with the SecItem* implementation. No call-site changes needed.
struct Keychain: KeychainStorage {

    /// Logical namespace for keys — kept for parity with the SecItem-based
    /// implementation we may switch back to. Currently embedded in the file
    /// path so different services don't share a file.
    let service: String

    /// Explicit storage URL. Defaults to
    /// `Application Support/<bundleName>/secrets-<service>.json` so the
    /// Debug and Release builds don't share a file. Tests inject a custom
    /// URL to keep them hermetic.
    let fileURL: URL

    init(service: String, fileURL: URL? = nil) {
        self.service = service
        self.fileURL = fileURL ?? Self.defaultFileURL(service: service)
    }

    // MARK: - KeychainStorage

    func setString(_ value: String, forKey key: String) throws {
        var dict = read()
        dict[key] = value
        try write(dict)
    }

    func getString(forKey key: String) -> String? {
        read()[key]
    }

    func deleteString(forKey key: String) throws {
        var dict = read()
        guard dict.removeValue(forKey: key) != nil else {
            // Post-condition (key not present) already satisfied.
            return
        }
        try write(dict)
    }

    // MARK: - Default storage path

    private static func defaultFileURL(service: String) -> URL {
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

        // Embed the service in the filename so different services (e.g.,
        // future per-feature secret namespaces) don't share a file.
        let safeService = service
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent("secrets-\(safeService).json")
    }

    // MARK: - Read / write

    private func read() -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private func write(_ dict: [String: String]) throws {
        do {
            let data = try JSONEncoder().encode(dict)
            try data.write(to: fileURL, options: [.atomic])
            // Tighten file permissions: user read/write only (`0600`).
            // Best-effort — fails silently if the file system doesn't support
            // POSIX permissions (none of our supported targets), but throws
            // on permission errors that mean something's actually wrong.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path(percentEncoded: false)
            )
        } catch {
            throw KeychainError.ioFailure(error.localizedDescription)
        }
    }
}
