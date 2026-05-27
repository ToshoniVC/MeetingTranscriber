import Testing
import Foundation
@testable import Jot

/// Tests for the pure `SettingsValidator`. Validation is per
/// Claude/implementation-plan.md §2 step 8: blank Base URL / Model / API Key
/// rejected, identical Watch+Output folders rejected.
struct SettingsValidationTests {

    // MARK: - Helpers

    private static let validURL   = "https://api.groq.com/openai/v1/audio/transcriptions"
    private static let validModel = "whisper-large-v3"
    private static let folderA    = Data([0xAA, 0xBB, 0xCC])
    private static let folderB    = Data([0xDD, 0xEE, 0xFF])

    private func validate(
        url: String = validURL,
        model: String = validModel,
        apiKey: Bool = true,
        watch: Data? = folderA,
        output: Data? = folderB
    ) -> [SettingsValidationIssue] {
        SettingsValidator.validate(
            apiBaseURL: url,
            modelString: model,
            apiKeyIsPresent: apiKey,
            watchFolderBookmark: watch,
            outputFolderBookmark: output
        )
    }

    // MARK: - Happy path

    @Test
    func fullyConfigured_returnsNoIssues() {
        #expect(validate().isEmpty)
    }

    // MARK: - Per-field rejection

    @Test
    func blankBaseURL_returnsBlankIssue() {
        let issues = validate(url: "")
        #expect(issues.contains(.blankAPIBaseURL))
    }

    @Test
    func whitespaceOnlyBaseURL_returnsBlankIssue() {
        let issues = validate(url: "   \t  ")
        #expect(issues.contains(.blankAPIBaseURL))
    }

    @Test
    func malformedBaseURL_returnsMalformedIssue() {
        // Missing scheme — fails the `URL(string:)?.scheme` check.
        let issues = validate(url: "not-a-url")
        #expect(issues.contains(.malformedAPIBaseURL))
    }

    @Test
    func blankModelString_returnsBlankIssue() {
        let issues = validate(model: "")
        #expect(issues.contains(.blankModelString))
    }

    @Test
    func missingAPIKey_returnsMissingIssue() {
        let issues = validate(apiKey: false)
        #expect(issues.contains(.missingAPIKey))
    }

    @Test
    func missingWatchFolder_returnsMissingIssue() {
        let issues = validate(watch: nil)
        #expect(issues.contains(.missingWatchFolder))
    }

    @Test
    func missingOutputFolder_returnsMissingIssue() {
        let issues = validate(output: nil)
        #expect(issues.contains(.missingOutputFolder))
    }

    // MARK: - Cross-field rule

    @Test
    func identicalWatchAndOutputBookmarks_returnsIdenticalIssue() {
        let same = Self.folderA
        let issues = validate(watch: same, output: same)
        #expect(issues.contains(.watchAndOutputFoldersIdentical))
    }

    @Test
    func differentBookmarks_doNotReportIdentical() {
        let issues = validate(watch: Self.folderA, output: Self.folderB)
        #expect(!issues.contains(.watchAndOutputFoldersIdentical))
    }

    // MARK: - Multiple problems

    @Test
    func multipleProblems_areAllReported() {
        let issues = validate(url: "", model: "", apiKey: false, watch: nil, output: nil)
        #expect(issues.contains(.blankAPIBaseURL))
        #expect(issues.contains(.blankModelString))
        #expect(issues.contains(.missingAPIKey))
        #expect(issues.contains(.missingWatchFolder))
        #expect(issues.contains(.missingOutputFolder))
    }

    // MARK: - Issue messages

    @Test
    func issueMessages_areNonEmpty() {
        let issues: [SettingsValidationIssue] = [
            .blankAPIBaseURL,
            .malformedAPIBaseURL,
            .blankModelString,
            .missingAPIKey,
            .watchAndOutputFoldersIdentical,
            .missingWatchFolder,
            .missingOutputFolder
        ]
        for issue in issues {
            #expect(!issue.message.isEmpty, "Issue \(issue) has empty message")
        }
    }
}
