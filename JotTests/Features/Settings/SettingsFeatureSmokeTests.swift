import Testing
@testable import Jot

/// Smoke tests for the Settings *feature* folder.
///
/// The substantive logic of the Settings feature (validation, persistence,
/// Keychain) lives under Core/Settings/ and is exhaustively covered by
/// JotTests/Core/Settings/. This file pins a couple of feature-level
/// contracts that the UI sections in Features/Settings/ rely on, so
/// changes there can't silently drift away from what the UI surfaces.
struct SettingsFeatureSmokeTests {

    @Test
    func foldersSection_issueMessages_areDistinctAndInformative() {
        // FoldersSection.swift renders these three issues inline. They must
        // have distinct, non-empty messages so the user can act on each
        // independently.
        let issues: [SettingsValidationIssue] = [
            .watchAndOutputFoldersIdentical,
            .missingWatchFolder,
            .missingOutputFolder
        ]
        let messages = Set(issues.map(\.message))
        #expect(messages.count == issues.count, "Issue messages should be distinct")
        for message in messages {
            #expect(!message.isEmpty)
        }
    }

    @Test
    func apiConfigSection_issueMessages_areDistinctAndInformative() {
        // APIConfigSection.swift uses these. Same contract as above.
        let issues: [SettingsValidationIssue] = [
            .blankAPIBaseURL,
            .malformedAPIBaseURL,
            .blankModelString,
            .missingAPIKey
        ]
        let messages = Set(issues.map(\.message))
        #expect(messages.count == issues.count)
        for message in messages {
            #expect(!message.isEmpty)
        }
    }
}
