import Foundation

/// Builds the `URLSession` every Jot HTTP client uses — transcription
/// uploads, Notion page writes, the Claude Code routine fire — with HTTP/3
/// switched off, so requests travel over TCP (HTTP/2, or HTTP/1.1 where the
/// server offers nothing better).
///
/// **Why (v0.7.3).** On macOS 27, URLSession reaches the Cloudflare-fronted
/// API hosts Jot talks to (Groq, OpenAI) over HTTP/3 (QUIC) from the very
/// first request. Its QUIC layer then sizes packets from the interface MTU
/// (1500) instead of the IPv6 link MTU the router advertises (1488 on the
/// home network this was diagnosed on), the kernel rejects every full-size
/// packet with `EMSGSIZE` ("Message too long"), and the stack never
/// recovers — Console shows "entering blackhole detection, setting PMTU to
/// 1280" over and over until the peer resets the connection. Small requests
/// never send a full-size packet, which is why the Settings connection
/// tests and Notion pings kept working while every audio upload failed with
/// "The network connection was lost" / "Request timed out", on *both*
/// providers: the failure is in the local QUIC path, not at either provider.
/// Reproduced from a standalone process against api.groq.com on
/// 2026-09-17; with HTTP/3 disabled the same 5 MB upload negotiated h2 and
/// completed in about a second.
///
/// **Why a private setter.** There is no public API to opt a `URLSession`
/// out of HTTP/3 (Apple DTS on the developer forums: "there's not a good
/// way to disable QUIC for a specific URLSession"). Ephemeral and fresh
/// sessions still negotiate h3 because discovery is system-wide (DNS HTTPS
/// records plus a shared Alt-Svc cache), and `assumesHTTP3Capable` only
/// opts *in*. The `URLSessionConfiguration` runtime does expose an
/// `_allowsHTTP3` property (`set_allowsHTTP3:`) that CFNetwork honours. We
/// flip it through Key-Value Coding, guarded by `responds(to:)`, so an OS
/// that drops the property degrades to today's behaviour (HTTP/3 allowed)
/// instead of crashing — and `NegotiatedProtocolRecorder` logs which
/// protocol each request actually used, so that regression is visible in
/// Console the moment it happens.
enum HTTPSessionPolicy {

    /// Session shared by the production HTTP clients. Built once, lazily,
    /// on first use. `URLSession` is thread-safe, so the actors that use it
    /// (`TranscriptionClient`, `NotionClient`, `ClaudeCodeRoutineClient`)
    /// can share one instance freely.
    static let shared: URLSession = makeSession()

    /// `true` when this OS exposes the HTTP/3 opt-out. Probed once against a
    /// throwaway configuration; both the setter and the getter must exist
    /// so `disableHTTP3(on:)` can verify its own write.
    static let http3OptOutAvailable: Bool = {
        let probe = URLSessionConfiguration.ephemeral
        return probe.responds(to: setterSelector) && probe.responds(to: getterSelector)
    }()

    /// Build a session from `configuration` with HTTP/3 disabled. The
    /// configuration is mutated in place — `URLSession` copies it on init,
    /// so the flag has to be set beforehand. Tests pass a configuration
    /// carrying `MockURLProtocol` to verify the policy doesn't disturb the
    /// `URLProtocol` path.
    static func makeSession(configuration: URLSessionConfiguration = .default) -> URLSession {
        let applied = disableHTTP3(on: configuration)
        if applied {
            Log.network.notice("HTTP session built with HTTP/3 disabled.")
        } else {
            Log.network.warning("HTTP session built WITHOUT the HTTP/3 opt-out (property unavailable on this OS) — uploads may stall on low-MTU links. See HTTPSessionPolicy.")
        }
        return URLSession(configuration: configuration)
    }

    /// Switch HTTP/3 off on `configuration`. Returns `true` when the flag
    /// was set *and* reads back as disabled; `false` when the OS doesn't
    /// expose the property (nothing is changed in that case).
    @discardableResult
    static func disableHTTP3(on configuration: URLSessionConfiguration) -> Bool {
        guard http3OptOutAvailable else { return false }
        configuration.setValue(false, forKey: key)
        return isHTTP3Disabled(on: configuration) == true
    }

    /// Read the flag back: `true` when HTTP/3 is disabled on
    /// `configuration`, `false` when it is allowed, `nil` when the OS
    /// doesn't expose the property at all.
    static func isHTTP3Disabled(on configuration: URLSessionConfiguration) -> Bool? {
        guard http3OptOutAvailable,
              let number = configuration.value(forKey: key) as? NSNumber
        else { return nil }
        return !number.boolValue
    }

    // MARK: - Private

    /// KVC key for the private `_allowsHTTP3` property. KVC maps it to the
    /// `set_allowsHTTP3:` setter observed in the CFNetwork runtime.
    private static let key = "_allowsHTTP3"
    private static let setterSelector = Selector(("set_allowsHTTP3:"))
    private static let getterSelector = Selector(("_allowsHTTP3"))
}
