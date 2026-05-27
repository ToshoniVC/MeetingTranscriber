import Foundation
@testable import Jot

/// Test fake for `WorkspaceActions` — records calls instead of touching
/// the real Finder / default-app launcher.
final class RecordingWorkspaceActions: WorkspaceActions, @unchecked Sendable {
    private(set) var revealCalls: [URL] = []
    private(set) var openCalls: [URL] = []

    func revealInFinder(_ url: URL) {
        revealCalls.append(url)
    }

    func openInDefaultApp(_ url: URL) {
        openCalls.append(url)
    }

    func reset() {
        revealCalls.removeAll()
        openCalls.removeAll()
    }
}
