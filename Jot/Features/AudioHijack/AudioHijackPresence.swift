import AppKit
import Foundation
import Observation

/// `@Observable` model representing "is Audio Hijack installed on this Mac?".
/// Owned by `JotApp` and bound by `HotkeySection` so the Settings tab can
/// surface installation status + a Download button when missing.
///
/// Detection strategy:
///   1. Ask `NSWorkspace` for the app URL of any of Rogue Amoeba's known
///      Audio Hijack bundle IDs.
///   2. Fall back to a small list of known install paths (in case
///      Launch Services hasn't indexed the app yet).
///
/// Both probes are injected so tests can substitute fakes — no real
/// NSWorkspace / FileManager hits during unit tests.
@MainActor
@Observable
final class AudioHijackPresence {

    /// URL of the installed Audio Hijack bundle, or `nil` if not detected.
    private(set) var url: URL?

    var isInstalled: Bool { url != nil }

    /// Bundle identifier read from the installed AH bundle (different across
    /// AH major versions). Used by `AudioHijackController` to target the
    /// right TCC entry when requesting Automation permission.
    var bundleID: String? {
        guard let url else { return nil }
        return bundleIDFromURL(url)
    }

    /// Rogue Amoeba's product page. Used by the "Download Audio Hijack"
    /// button when not installed.
    static let downloadURL = URL(string: "https://rogueamoeba.com/audiohijack/")!

    typealias BundleIDLookup = @MainActor (String) -> URL?
    typealias PathExistsCheck = @MainActor (String) -> Bool
    typealias BundleIDFromURL = @MainActor (URL) -> String?

    private let bundleIDLookup: BundleIDLookup
    private let pathExistsCheck: PathExistsCheck
    private let bundleIDFromURL: BundleIDFromURL

    init(
        bundleIDLookup: @escaping BundleIDLookup = { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        },
        pathExistsCheck: @escaping PathExistsCheck = { path in
            FileManager.default.fileExists(atPath: path)
        },
        bundleIDFromURL: @escaping BundleIDFromURL = { url in
            Bundle(url: url)?.bundleIdentifier
        }
    ) {
        self.bundleIDLookup = bundleIDLookup
        self.pathExistsCheck = pathExistsCheck
        self.bundleIDFromURL = bundleIDFromURL
        refresh()
    }

    /// Re-run detection. Wired to a "Recheck" button so the user can flip
    /// the indicator after installing AH without restarting Jot.
    func refresh() {
        url = detect()
    }

    private func detect() -> URL? {
        // Try Launch Services first — succeeds even if AH is in a non-standard
        // install location.
        for id in Self.knownBundleIDs {
            if let found = bundleIDLookup(id) {
                return found
            }
        }
        // Fallback: known install paths. Helpful right after install before
        // Launch Services has caught up.
        for path in Self.knownInstallPaths {
            if pathExistsCheck(path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Rogue Amoeba has rotated bundle IDs across major versions. Try them all.
    static let knownBundleIDs: [String] = [
        "com.rogueamoeba.AudioHijack",
        "com.rogueamoeba.audiohijack",
        "com.rogueamoeba.AudioHijack3",
        "com.rogueamoeba.AudioHijack4",
    ]

    static let knownInstallPaths: [String] = [
        "/Applications/Audio Hijack.app",
        "/Applications/Audio Hijack 3.app",
        "/Applications/Audio Hijack 4.app",
    ]
}
