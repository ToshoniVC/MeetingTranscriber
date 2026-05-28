import Foundation

/// Read-only access to the running bundle's version strings.
///
/// `CFBundleShortVersionString` is the user-visible "marketing" version
/// (`0.1.0`, set by the release workflow from the tag) and `CFBundleVersion`
/// is the monotonic build number (`git rev-list --count HEAD`). Both come
/// from `Info.plist` via build-setting substitution — see
/// `Jot/Config/{Debug,Release}.xcconfig` and the release workflow's
/// `MARKETING_VERSION=` / `CURRENT_PROJECT_VERSION=` overrides.
///
/// The fallbacks below only fire if `Info.plist` is somehow missing the
/// keys — unreachable for a properly built app, but graceful for any
/// future test-harness that loads the module standalone.
enum AppVersion {
    /// Marketing version, e.g. `"0.1.0"`. Shown to the user.
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Build number, e.g. `"26"`. Monotonic; useful for crash reports +
    /// the audit log if we ever decide to include it.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Combined display string, e.g. `"0.1.0 (26)"`. Used by the sidebar
    /// footer in `MainWindow`.
    static var display: String {
        "\(marketing) (\(build))"
    }
}
