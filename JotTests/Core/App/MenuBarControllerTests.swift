import Testing
import Foundation
@testable import Jot

/// Tests for `MenuBarController` — the small @Observable state object the
/// `MenuBarExtra` label binds to in `JotApp.swift`. Phase 5 reshaped this
/// type from a Phase 0 placeholder into a real `PipelineState` mirror.
@MainActor
struct MenuBarControllerTests {

    @Test
    func init_defaultsToNotConfigured() {
        let controller = MenuBarController()
        #expect(controller.iconState == .notConfigured)
        #expect(controller.isProcessing == false)
    }

    @Test
    func isProcessing_trueOnlyForProcessingState() {
        let controller = MenuBarController()

        controller.iconState = .idle
        #expect(controller.isProcessing == false)

        let url = URL(fileURLWithPath: "/tmp/meeting.mp3")
        controller.iconState = .processing(url)
        #expect(controller.isProcessing == true)

        controller.iconState = .error(url, "boom")
        #expect(controller.isProcessing == false)

        controller.iconState = .notConfigured
        #expect(controller.isProcessing == false)
    }

    @Test
    func statusLine_describesEachState() {
        let controller = MenuBarController()
        let url = URL(fileURLWithPath: "/tmp/meeting.mp3")

        controller.iconState = .notConfigured
        #expect(controller.statusLine == "Not yet configured")

        controller.iconState = .idle
        #expect(controller.statusLine.contains("Idle"))

        controller.iconState = .processing(url)
        #expect(controller.statusLine.contains("meeting.mp3"))
        #expect(controller.statusLine.contains("Transcribing"))

        controller.iconState = .error(url, "API key was rejected")
        #expect(controller.statusLine.contains("Error"))
        #expect(controller.statusLine.contains("API key was rejected"))
    }
}
