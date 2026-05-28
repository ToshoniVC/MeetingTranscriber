import Testing
@testable import Jot

/// Tiny smoke tests for `DebugMode`. The class is a single boolean with a
/// toggle method, but the test pins the contract (default OFF, toggle
/// flips, repeated toggles cancel out) so a future refactor doesn't
/// silently change the launch-time behavior of verbose logging.
@MainActor
struct DebugModeTests {

    @Test
    func init_defaultsToOff() {
        #expect(DebugMode().isVerbose == false)
    }

    @Test
    func toggle_flipsTheFlag() {
        let mode = DebugMode()
        mode.toggle()
        #expect(mode.isVerbose == true)
        mode.toggle()
        #expect(mode.isVerbose == false)
    }

    @Test
    func directAssignment_alsoWorks() {
        // Some call sites may want to force a specific state rather than
        // toggle (e.g., resetting at session boundaries). Verify the
        // setter is publicly accessible.
        let mode = DebugMode()
        mode.isVerbose = true
        #expect(mode.isVerbose == true)
    }
}
