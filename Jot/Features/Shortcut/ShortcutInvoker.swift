import AppKit
import Foundation

/// Errors `ShortcutInvoker` throws.
enum ShortcutError: Error, Equatable {
    /// `NSWorkspace.open(_:)` rejected the `shortcuts://` URL — most likely
    /// because the URL couldn't be built (empty name) or the Shortcuts app
    /// isn't available on this machine (vanishingly rare on macOS 12+).
    ///
    /// Note: this does NOT fire when the named Shortcut doesn't exist —
    /// `NSWorkspace.open` only knows whether the URL handler accepted the
    /// invocation, not whether the Shortcut itself succeeded. Mis-named
    /// Shortcuts surface inside the Shortcuts app, not back to us.
    case openFailed(String)

    var userFacingMessage: String {
        switch self {
        case .openFailed(let message):
            return "Couldn't open the Shortcuts URL: \(message)"
        }
    }
}

/// Abstracts opening a URL via `NSWorkspace` so tests can verify the exact
/// URL we'd hand to macOS without actually launching Shortcuts.
///
/// Not actor-isolated: `NSWorkspace.shared.open(_:configuration:)` is the
/// modern async API and can be invoked from any context. Keeping this
/// protocol non-isolated lets the production opener be used as a default
/// initializer value for `ShortcutInvoker`.
protocol URLOpening: Sendable {
    func open(_ url: URL) async throws
}

/// Production opener. Uses `OpenConfiguration.activates = false` so
/// Shortcuts doesn't yank focus when the user fires the hotkey from
/// another app — the Shortcut still runs, just without bringing
/// Shortcuts.app to the foreground.
struct SystemURLOpener: URLOpening {
    func open(_ url: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.open(url, configuration: config)
    }
}

/// Invokes a user-defined Apple Shortcut by name.
///
/// Per PRD §5: pressing the recording hotkey should trigger an Apple
/// Shortcut that drives Audio Hijack. We talk to Shortcuts via its
/// `shortcuts://run-shortcut?name=…&input=…` URL scheme rather than the
/// `/usr/bin/shortcuts` CLI, because spawning the CLI from a sandboxed
/// app crashes the CLI process — it tries to write to paths that don't
/// exist inside our container (`Data.write(to:)` with a nil URL).
///
/// URL-scheme invocation hops out of our sandbox cleanly: the Shortcuts
/// daemon runs the workflow in its own process with its own permissions.
/// The trade-off: we can't observe the Shortcut's exit code or whether
/// the named Shortcut even exists — that feedback would require
/// registering Jot for x-callback-url responses, which we'll do later
/// if a real user runs into it. For now, our typed errors only cover
/// "couldn't even hand off the URL".
struct ShortcutInvoker {
    private let opener: any URLOpening

    init(opener: any URLOpening = SystemURLOpener()) {
        self.opener = opener
    }

    /// Run the named Shortcut. `input`, when non-nil, becomes the
    /// Shortcut's `Shortcut Input` (a string the user can read inside the
    /// workflow). Used to pipe the meeting name from Jot's prompter into
    /// the Start Shortcut.
    func run(shortcutName: String, input: String? = nil) async throws {
        guard let url = Self.makeURL(shortcutName: shortcutName, input: input) else {
            throw ShortcutError.openFailed("Couldn't build URL for Shortcut '\(shortcutName)'")
        }
        do {
            try await opener.open(url)
        } catch {
            throw ShortcutError.openFailed(error.localizedDescription)
        }
    }

    /// Build `shortcuts://run-shortcut?name=…&input=…`. Visible to tests so
    /// they can assert on the exact URL we'd ask macOS to open.
    static func makeURL(shortcutName: String, input: String?) -> URL? {
        let trimmed = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var items: [URLQueryItem] = [URLQueryItem(name: "name", value: trimmed)]
        if let input, !input.isEmpty {
            items.append(URLQueryItem(name: "input", value: input))
        }
        components.queryItems = items
        return components.url
    }
}
