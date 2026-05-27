import Foundation

/// Helper that returns a fresh `UserDefaults` suite for a single test, then
/// nukes it at the end. Tests using this never read or write the real
/// `.standard` suite, so they're hermetic and parallel-safe.
///
/// Usage:
/// ```swift
/// let defaults = EphemeralUserDefaults.make()
/// defer { EphemeralUserDefaults.tearDown(defaults) }
/// ```
enum EphemeralUserDefaults {
    static func make(file: StaticString = #file, line: UInt = #line) -> UserDefaults {
        let suiteName = "jot.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create ephemeral UserDefaults at \(file):\(line)")
        }
        // Belt-and-suspenders: clear any keys an earlier crashed test may have
        // left behind (suite names are random, so this should be a no-op).
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        return defaults
    }

    /// Wipe and unregister the suite. Always call from a `defer` block.
    static func tearDown(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}
