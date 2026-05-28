import Testing
import Foundation
@testable import Jot

/// Unit tests for `ErrorInspector` — the `@Observable` holder of the
/// currently-displayed error details. We assert on `currentError` after
/// each show()/dismiss() call.
@MainActor
struct ErrorInspectorTests {

    @Test
    func init_currentError_isNil() {
        let inspector = ErrorInspector()
        #expect(inspector.currentError == nil)
    }

    @Test
    func show_fromAuditLogEntry_populatesAllFields() {
        let inspector = ErrorInspector()
        let entry = AuditLogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .failure,
            sourcePath: "/tmp/some-file.mp3",
            message: "Transcription failed: 401 Unauthorized",
            retryable: true
        )

        inspector.show(from: entry)

        let details = try? #require(inspector.currentError)
        #expect(details?.title == "Pipeline error")
        #expect(details?.message.contains("401 Unauthorized") == true)
        #expect(details?.sourcePath == "/tmp/some-file.mp3")
        #expect(details?.timestamp == entry.timestamp)
    }

    @Test
    func show_fromPipelineState_errorCase_populatesFields() {
        let inspector = ErrorInspector()
        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        let state = PipelineState.error(url, "Network unreachable")

        inspector.show(pipelineState: state)

        let details = try? #require(inspector.currentError)
        #expect(details?.message == "Network unreachable")
        #expect(details?.sourcePath == "/tmp/audio.mp3")
    }

    @Test
    func show_fromPipelineState_nonErrorCase_isNoOp() {
        let inspector = ErrorInspector()

        inspector.show(pipelineState: .idle)
        #expect(inspector.currentError == nil)

        inspector.show(pipelineState: .notConfigured)
        #expect(inspector.currentError == nil)

        inspector.show(pipelineState: .processing(URL(fileURLWithPath: "/tmp/x.mp3")))
        #expect(inspector.currentError == nil)
    }

    @Test
    func dismiss_clearsCurrentError() {
        let inspector = ErrorInspector()
        inspector.show(pipelineState: .error(URL(fileURLWithPath: "/tmp/y.mp3"), "boom"))
        #expect(inspector.currentError != nil)

        inspector.dismiss()
        #expect(inspector.currentError == nil)
    }

    @Test
    func twoShows_inSuccession_replaceCurrentError_withDistinctId() {
        let inspector = ErrorInspector()
        inspector.show(pipelineState: .error(URL(fileURLWithPath: "/tmp/a"), "first"))
        let firstId = inspector.currentError?.id

        inspector.show(pipelineState: .error(URL(fileURLWithPath: "/tmp/b"), "second"))
        let secondId = inspector.currentError?.id

        #expect(firstId != nil)
        #expect(secondId != nil)
        #expect(firstId != secondId, "Each show() should produce a fresh ID so SwiftUI re-presents the sheet")
        #expect(inspector.currentError?.message == "second")
    }
}
