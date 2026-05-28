import Testing
import Foundation
@testable import Jot

/// Tests for `ShortcutInvoker` using `RecordingURLOpener` so no real
/// `NSWorkspace.open` fires and no Shortcuts app gets launched.
@MainActor
struct ShortcutInvokerTests {

    // MARK: - URL construction

    @Test
    func makeURL_basicName_buildsShortcutsRunURL() {
        let url = ShortcutInvoker.makeURL(shortcutName: "Jot Start Recording", input: nil)
        let asString = url?.absoluteString
        #expect(asString == "shortcuts://run-shortcut?name=Jot%20Start%20Recording")
    }

    @Test
    func makeURL_withInput_appendsInputQueryItem() {
        let url = ShortcutInvoker.makeURL(shortcutName: "Jot Start Recording", input: "Standup")
        let asString = url?.absoluteString
        #expect(asString?.contains("name=Jot%20Start%20Recording") == true)
        #expect(asString?.contains("input=Standup") == true)
    }

    @Test
    func makeURL_emptyInput_omitsInputParam() {
        let url = ShortcutInvoker.makeURL(shortcutName: "X", input: "")
        let asString = url?.absoluteString
        #expect(asString?.contains("input=") == false)
    }

    @Test
    func makeURL_whitespaceOnlyName_returnsNil() {
        #expect(ShortcutInvoker.makeURL(shortcutName: "   ", input: nil) == nil)
        #expect(ShortcutInvoker.makeURL(shortcutName: "", input: nil) == nil)
    }

    @Test
    func makeURL_trimsNameWhitespace() {
        let url = ShortcutInvoker.makeURL(shortcutName: "  Jot Start  ", input: nil)
        #expect(url?.absoluteString == "shortcuts://run-shortcut?name=Jot%20Start")
    }

    @Test
    func makeURL_unicodeName_percentEncoded() {
        // Make sure non-ASCII characters in Shortcut names don't break URL
        // construction (the user might use a Shortcut name with emoji, etc.).
        let url = ShortcutInvoker.makeURL(shortcutName: "Récord ▶️", input: nil)
        #expect(url != nil)
        // Spot-check that the encoded form round-trips back to the original.
        let decoded = url?.queryItems(named: "name").first
        #expect(decoded == "Récord ▶️")
    }

    // MARK: - run()

    @Test
    func run_handsURLToOpener_withoutInput() async throws {
        let opener = RecordingURLOpener()
        let invoker = ShortcutInvoker(opener: opener)
        try await invoker.run(shortcutName: "Jot Start Recording")
        #expect(opener.openedURLs.count == 1)
        #expect(opener.openedURLs[0].host == "run-shortcut")
        #expect(opener.openedURLs[0].queryItems(named: "name").first == "Jot Start Recording")
        #expect(opener.openedURLs[0].queryItems(named: "input").isEmpty)
    }

    @Test
    func run_pipesInputAsQueryItem() async throws {
        let opener = RecordingURLOpener()
        let invoker = ShortcutInvoker(opener: opener)
        try await invoker.run(shortcutName: "Jot Start Recording", input: "Demo Meeting")
        #expect(opener.openedURLs.count == 1)
        #expect(opener.openedURLs[0].queryItems(named: "input").first == "Demo Meeting")
    }

    @Test
    func run_emptyName_throwsOpenFailed() async {
        let opener = RecordingURLOpener()
        let invoker = ShortcutInvoker(opener: opener)
        do {
            try await invoker.run(shortcutName: "")
            Issue.record("Expected throw")
        } catch let error as ShortcutError {
            if case .openFailed = error { /* ok */ } else { Issue.record("Wrong case: \(error)") }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(opener.openedURLs.isEmpty, "Should never reach the opener on an unusable name")
    }

    @Test
    func run_openerFailure_propagatesAsOpenFailed() async {
        let opener = RecordingURLOpener()
        opener.nextError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Shortcuts app not available"
        ])
        let invoker = ShortcutInvoker(opener: opener)
        do {
            try await invoker.run(shortcutName: "X")
            Issue.record("Expected throw")
        } catch let error as ShortcutError {
            if case .openFailed(let message) = error {
                #expect(message.contains("not available"))
            } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func userFacingMessage_nonEmpty() {
        #expect(!ShortcutError.openFailed("nope").userFacingMessage.isEmpty)
    }
}

/// Small URL helper so the assertions above stay readable.
private extension URL {
    func queryItems(named name: String) -> [String] {
        guard let comps = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return [] }
        return items.compactMap { $0.name == name ? $0.value : nil }
    }
}
