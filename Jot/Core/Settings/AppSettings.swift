import Foundation
import Observation

/// `AppSettings` is the single source of truth for all user-configurable state
/// in Jot. The plain properties below are persisted to `UserDefaults` (`apiKey`
/// is the exception — it lives in the Keychain via `KeychainStorage`).
///
/// Per PRD §3.2 Tab 3, the fields are: API Base URL, Model String, API Key,
/// Watch Folder, Output Folder, Recording Hotkey, Launch on Startup.
///
/// Why @Observable + `didSet`-based autosave (and not @AppStorage):
/// - `@AppStorage` is SwiftUI-scoped and doesn't play cleanly inside an
///   `@Observable` model class.
/// - We want explicit testability: tests inject a custom `UserDefaults` and a
///   fake `KeychainStorage`, then assert on persistence behavior end-to-end.
@MainActor
@Observable
final class AppSettings {

    // MARK: - Persistent properties

    var apiBaseURL: String {
        didSet { defaults.set(apiBaseURL, forKey: Keys.apiBaseURL) }
    }

    var modelString: String {
        didSet { defaults.set(modelString, forKey: Keys.modelString) }
    }

    /// Security-scoped bookmark data for the Watch Folder. Resolved at use
    /// site (Phase 2 Watcher) via
    /// `URL(resolvingBookmarkData:options:.withSecurityScope...)`.
    var watchFolderBookmark: Data? {
        didSet { defaults.set(watchFolderBookmark, forKey: Keys.watchFolderBookmark) }
    }

    /// Security-scoped bookmark data for the Output Folder.
    var outputFolderBookmark: Data? {
        didSet { defaults.set(outputFolderBookmark, forKey: Keys.outputFolderBookmark) }
    }

    var recordingHotkey: KeyCombo? {
        didSet {
            if let recordingHotkey {
                defaults.set(try? JSONEncoder().encode(recordingHotkey), forKey: Keys.recordingHotkey)
            } else {
                defaults.removeObject(forKey: Keys.recordingHotkey)
            }
        }
    }

    var launchOnStartup: Bool {
        didSet { defaults.set(launchOnStartup, forKey: Keys.launchOnStartup) }
    }

    // MARK: - Keychain-backed property

    /// API key for the transcription endpoint. Round-trips through Keychain
    /// (never `UserDefaults`, never disk). Setting `nil` deletes the entry.
    var apiKey: String? {
        get { keychain.getString(forKey: Self.apiKeyAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                try? keychain.setString(newValue, forKey: Self.apiKeyAccount)
            } else {
                try? keychain.deleteString(forKey: Self.apiKeyAccount)
            }
        }
    }

    // MARK: - Init

    private let defaults: UserDefaults
    private let keychain: KeychainStorage

    init(defaults: UserDefaults = .standard, keychain: KeychainStorage? = nil) {
        self.defaults = defaults
        // Default keychain uses the bundle ID as the service name so Debug
        // (Jot Dev) and Release (Jot) builds get fully separated entries.
        self.keychain = keychain ?? Keychain(
            service: Bundle.main.bundleIdentifier ?? "com.toshonivc.jot"
        )

        self.apiBaseURL = defaults.string(forKey: Keys.apiBaseURL) ?? ""
        self.modelString = defaults.string(forKey: Keys.modelString) ?? ""
        self.watchFolderBookmark = defaults.data(forKey: Keys.watchFolderBookmark)
        self.outputFolderBookmark = defaults.data(forKey: Keys.outputFolderBookmark)
        if let data = defaults.data(forKey: Keys.recordingHotkey) {
            self.recordingHotkey = try? JSONDecoder().decode(KeyCombo.self, from: data)
        } else {
            self.recordingHotkey = nil
        }
        self.launchOnStartup = defaults.bool(forKey: Keys.launchOnStartup)
    }

    // MARK: - UserDefaults keys (centralized to avoid string typos)

    private enum Keys {
        static let apiBaseURL          = "jot.settings.apiBaseURL"
        static let modelString         = "jot.settings.modelString"
        static let watchFolderBookmark = "jot.settings.watchFolderBookmark"
        static let outputFolderBookmark = "jot.settings.outputFolderBookmark"
        static let recordingHotkey     = "jot.settings.recordingHotkey"
        static let launchOnStartup     = "jot.settings.launchOnStartup"
    }

    /// Keychain `account` for the API key entry. The `service` is set in `init`.
    static let apiKeyAccount = "api_key"
}
