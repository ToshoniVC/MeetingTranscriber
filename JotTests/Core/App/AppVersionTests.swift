import Testing
import Foundation
@testable import Jot

/// Smoke tests for `AppVersion`. We can't assert on specific version strings
/// (they change every release) but we *can* pin the contract: the values
/// never come back empty, the display format combines marketing + build,
/// and the fallbacks fire if the test bundle is missing Info.plist keys.
struct AppVersionTests {

    @Test
    func marketing_isNonEmpty() {
        let value = AppVersion.marketing
        #expect(!value.isEmpty)
    }

    @Test
    func build_isNonEmpty() {
        let value = AppVersion.build
        #expect(!value.isEmpty)
    }

    @Test
    func display_combinesMarketingAndBuild() {
        // Spot-check the rendered shape. We don't assert the actual numbers
        // (they shift each release) — just that the format stays
        // "<marketing> (<build>)" so the sidebar footer doesn't end up
        // mangled if someone refactors AppVersion.
        let value = AppVersion.display
        #expect(value.contains(AppVersion.marketing))
        #expect(value.contains("(\(AppVersion.build))"))
    }
}
