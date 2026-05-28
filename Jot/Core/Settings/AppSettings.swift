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

    /// When the recording hotkey fires, use Jot's built-in toggle flow
    /// (`true`, the default) — Jot prompts for a meeting name and runs
    /// `startShortcutName` / `stopShortcutName` based on its own local
    /// view of "is recording right now?". Set to `false` to bypass the
    /// prompt and the state tracking and just run `customShortcutName`
    /// on every hotkey press (the user's Shortcut handles everything).
    var useBuiltInRecording: Bool {
        didSet { defaults.set(useBuiltInRecording, forKey: Keys.useBuiltInRecording) }
    }

    /// Name of the Apple Shortcut Jot runs to **start** recording in
    /// the built-in flow. The user authors this Shortcut to invoke Audio
    /// Hijack 4's `Run/Stop Session` intent with `state = running`.
    /// Default `"Jot Start Recording"`.
    var startShortcutName: String {
        didSet { defaults.set(startShortcutName, forKey: Keys.startShortcutName) }
    }

    /// Name of the Apple Shortcut Jot runs to **stop** recording in the
    /// built-in flow. Author with `state = stopped`. Default `"Jot Stop Recording"`.
    var stopShortcutName: String {
        didSet { defaults.set(stopShortcutName, forKey: Keys.stopShortcutName) }
    }

    /// Name of the Apple Shortcut Jot runs in the custom flow (no prompt,
    /// no state tracking). Default `"Jot Toggle Recording"` — user-authored
    /// to handle both start/stop themselves.
    var customShortcutName: String {
        didSet { defaults.set(customShortcutName, forKey: Keys.customShortcutName) }
    }

    var launchOnStartup: Bool {
        didSet { defaults.set(launchOnStartup, forKey: Keys.launchOnStartup) }
    }

    /// Master toggle for the Notion meeting-creation bridge. When `false`
    /// (the default) the rest of the Notion config is ignored and no
    /// network traffic ever flows to Notion.
    var notionEnabled: Bool {
        didSet { defaults.set(notionEnabled, forKey: Keys.notionEnabled) }
    }

    /// Notion database ID where new meeting pages are created. The user
    /// pastes this from the database URL — a 32-char hex string, optionally
    /// hyphenated. Stored as raw text; `NotionValidation` decides whether
    /// it's well-formed enough to attempt a write.
    var notionDatabaseId: String {
        didSet { defaults.set(notionDatabaseId, forKey: Keys.notionDatabaseId) }
    }

    // MARK: - Keychain-backed properties

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

    /// Notion integration token (a `secret_...` string from a Notion
    /// internal integration). Round-trips through Keychain alongside
    /// `apiKey`. Setting `nil` or empty deletes the entry.
    var notionToken: String? {
        get { keychain.getString(forKey: Self.notionTokenAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                try? keychain.setString(newValue, forKey: Self.notionTokenAccount)
            } else {
                try? keychain.deleteString(forKey: Self.notionTokenAccount)
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
        self.startShortcutName = defaults.string(forKey: Keys.startShortcutName) ?? "Jot Start Recording"
        self.stopShortcutName = defaults.string(forKey: Keys.stopShortcutName) ?? "Jot Stop Recording"
        self.customShortcutName = defaults.string(forKey: Keys.customShortcutName) ?? "Jot Toggle Recording"
        // `useBuiltInRecording` defaults to true on a fresh install — that's
        // the out-of-the-box experience. UserDefaults stores it as a Bool
        // and `bool(forKey:)` returns false for missing keys, so detect
        // "missing" by checking the object form.
        if defaults.object(forKey: Keys.useBuiltInRecording) == nil {
            self.useBuiltInRecording = true
        } else {
            self.useBuiltInRecording = defaults.bool(forKey: Keys.useBuiltInRecording)
        }
        self.launchOnStartup = defaults.bool(forKey: Keys.launchOnStartup)
        self.notionEnabled = defaults.bool(forKey: Keys.notionEnabled)
        self.notionDatabaseId = defaults.string(forKey: Keys.notionDatabaseId) ?? ""
    }

    // MARK: - UserDefaults keys (centralized to avoid string typos)

    private enum Keys {
        static let apiBaseURL          = "jot.settings.apiBaseURL"
        static let modelString         = "jot.settings.modelString"
        static let watchFolderBookmark = "jot.settings.watchFolderBookmark"
        static let outputFolderBookmark = "jot.settings.outputFolderBookmark"
        static let recordingHotkey     = "jot.settings.recordingHotkey"
        static let startShortcutName   = "jot.settings.startShortcutName"
        static let stopShortcutName    = "jot.settings.stopShortcutName"
        static let customShortcutName  = "jot.settings.customShortcutName"
        static let useBuiltInRecording = "jot.settings.useBuiltInRecording"
        static let launchOnStartup     = "jot.settings.launchOnStartup"
        static let notionEnabled       = "jot.settings.notionEnabled"
        static let notionDatabaseId    = "jot.settings.notionDatabaseId"
    }

    /// Keychain `account` for the API key entry. The `service` is set in `init`.
    static let apiKeyAccount = "api_key"

    /// Keychain `account` for the Notion integration token. Separate from
    /// `apiKeyAccount` so the two secrets are independently rotatable.
    static let notionTokenAccount = "notion_token"
}
