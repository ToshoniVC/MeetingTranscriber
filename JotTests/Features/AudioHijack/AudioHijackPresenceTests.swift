import Testing
import Foundation
@testable import Jot

/// Tests for `AudioHijackPresence`. Both probes (bundle ID lookup and path
/// existence) are injected so no real `NSWorkspace` / `FileManager` calls
/// reach the test machine.
@MainActor
struct AudioHijackPresenceTests {

    // MARK: - Detection via bundle ID

    @Test
    func init_findsAppViaBundleID() {
        let foundURL = URL(fileURLWithPath: "/Applications/Audio Hijack.app")
        let presence = AudioHijackPresence(
            bundleIDLookup: { id in
                // Match the first known bundle ID we try.
                id == AudioHijackPresence.knownBundleIDs.first ? foundURL : nil
            },
            pathExistsCheck: { _ in false }
        )
        #expect(presence.isInstalled)
        #expect(presence.url == foundURL)
    }

    @Test
    func init_findsAppViaSecondaryBundleID() {
        // Simulate AH installed under a non-first bundle ID.
        let foundURL = URL(fileURLWithPath: "/Applications/Audio Hijack.app")
        let target = AudioHijackPresence.knownBundleIDs[1]
        let presence = AudioHijackPresence(
            bundleIDLookup: { id in id == target ? foundURL : nil },
            pathExistsCheck: { _ in false }
        )
        #expect(presence.url == foundURL)
    }

    // MARK: - Fallback to path

    @Test
    func init_fallsBackToInstallPath_whenBundleLookupFails() {
        let knownPath = AudioHijackPresence.knownInstallPaths.first ?? ""
        let presence = AudioHijackPresence(
            bundleIDLookup: { _ in nil },
            pathExistsCheck: { path in path == knownPath }
        )
        #expect(presence.isInstalled)
        #expect(presence.url?.path(percentEncoded: false) == knownPath)
    }

    @Test
    func init_returnsNil_whenNothingFound() {
        let presence = AudioHijackPresence(
            bundleIDLookup: { _ in nil },
            pathExistsCheck: { _ in false }
        )
        #expect(presence.isInstalled == false)
        #expect(presence.url == nil)
    }

    // MARK: - Refresh

    @Test
    func refresh_updatesStateWhenAvailabilityChanges() {
        // Use a mutable Box so the closure can flip its return value.
        final class Box { var found: URL? }
        let box = Box()
        let presence = AudioHijackPresence(
            bundleIDLookup: { _ in box.found },
            pathExistsCheck: { _ in false }
        )
        #expect(presence.isInstalled == false)

        // User installs Audio Hijack — flip + recheck.
        box.found = URL(fileURLWithPath: "/Applications/Audio Hijack.app")
        presence.refresh()
        #expect(presence.isInstalled)

        // User uninstalls — flip back + recheck.
        box.found = nil
        presence.refresh()
        #expect(presence.isInstalled == false)
    }

    // MARK: - Download URL

    @Test
    func downloadURL_isRogueAmoebaProductPage() {
        #expect(AudioHijackPresence.downloadURL.host == "rogueamoeba.com")
        #expect(AudioHijackPresence.downloadURL.path.contains("audiohijack"))
    }
}
