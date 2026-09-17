import Testing
import Foundation
@testable import Jot

/// Unit tests for `NegotiatedProtocolRecorder` (v0.7.3). The delegate
/// callback can't be fed real transaction metrics (URLSession owns them,
/// and `URLSessionTaskMetrics.init()` is deprecated as unsupported), so the
/// formatting and classification live behind pure static helpers that
/// these tests pin. The delegate plumbing itself is exercised end to end
/// by `HTTPSessionPolicyIntegrationTests` through a real `URLSession`.
struct NegotiatedProtocolRecorderTests {

    @Test
    func summary_beforeAnyMetrics_isUnknownAndNotHTTP3() {
        let recorder = NegotiatedProtocolRecorder()
        #expect(recorder.protocols.isEmpty)
        #expect(recorder.summary == "unknown")
        #expect(!recorder.usedHTTP3)
    }

    @Test
    func summarize_joinsNamedProtocolsInOrder() {
        #expect(NegotiatedProtocolRecorder.summarize(["h2"]) == "h2")
        #expect(NegotiatedProtocolRecorder.summarize(["h3", "h2"]) == "h3, h2")
    }

    @Test
    func summarize_dropsUnnamedTransactions() {
        #expect(NegotiatedProtocolRecorder.summarize(["", "h2"]) == "h2")
        #expect(NegotiatedProtocolRecorder.summarize(["", ""]) == "unknown")
        #expect(NegotiatedProtocolRecorder.summarize([]) == "unknown")
    }

    @Test
    func usesHTTP3_matchesH3CaseInsensitivelyAnywhereInTheChain() {
        #expect(NegotiatedProtocolRecorder.usesHTTP3(["h3"]))
        #expect(NegotiatedProtocolRecorder.usesHTTP3(["H3", "h2"]))
        #expect(NegotiatedProtocolRecorder.usesHTTP3(["h2", "h3"]))
        #expect(!NegotiatedProtocolRecorder.usesHTTP3(["h2"]))
        #expect(!NegotiatedProtocolRecorder.usesHTTP3(["http/1.1"]))
        #expect(!NegotiatedProtocolRecorder.usesHTTP3([]))
    }
}
