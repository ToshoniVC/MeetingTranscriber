import Foundation

/// One validation problem detected by `SettingsValidator`. Each case carries
/// enough information for the UI to highlight the specific offending field.
enum SettingsValidationIssue: Equatable, Sendable {
    case blankAPIBaseURL
    case malformedAPIBaseURL
    case blankModelString
    case missingAPIKey
    case watchAndOutputFoldersIdentical
    case missingWatchFolder
    case missingOutputFolder

    /// Human-readable message shown inline next to the offending field.
    var message: String {
        switch self {
        case .blankAPIBaseURL:
            return "API Base URL is required."
        case .malformedAPIBaseURL:
            return "API Base URL must be a valid URL (e.g. https://api.groq.com/openai/v1/audio/transcriptions)."
        case .blankModelString:
            return "Model string is required (e.g. whisper-large-v3)."
        case .missingAPIKey:
            return "API Key is required."
        case .watchAndOutputFoldersIdentical:
            return "Watch Folder and Output Folder must be different."
        case .missingWatchFolder:
            return "Watch Folder must be set."
        case .missingOutputFolder:
            return "Output Folder must be set."
        }
    }
}

/// Pure validation logic for `AppSettings`. No side effects, no I/O — every
/// dependency is passed in. That keeps `SettingsValidationTests` fast and
/// hermetic.
///
/// Validation runs continuously (any time settings change) rather than only on
/// a "Save" button click — Jot autosaves. The UI surfaces issues inline; the
/// transcription pipeline (Phase 5) refuses to run while there are issues.
enum SettingsValidator {

    /// Inspect a snapshot of settings + the resolved API key and return every
    /// issue found. An empty array means the configuration is valid.
    static func validate(
        apiBaseURL: String,
        modelString: String,
        apiKeyIsPresent: Bool,
        watchFolderBookmark: Data?,
        outputFolderBookmark: Data?
    ) -> [SettingsValidationIssue] {
        var issues: [SettingsValidationIssue] = []

        let trimmedURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            issues.append(.blankAPIBaseURL)
        } else if URL(string: trimmedURL)?.scheme == nil {
            // Reject anything that doesn't at least look like a URL with a
            // scheme. We deliberately don't validate the host or that the
            // endpoint exists — that's what the "Test connection" button is
            // for (wired in Phase 3 when the transcription client lands).
            issues.append(.malformedAPIBaseURL)
        }

        if modelString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.blankModelString)
        }

        if !apiKeyIsPresent {
            issues.append(.missingAPIKey)
        }

        if watchFolderBookmark == nil {
            issues.append(.missingWatchFolder)
        }
        if outputFolderBookmark == nil {
            issues.append(.missingOutputFolder)
        }

        // PRD §4.2 implies watch and output folders must differ — files move
        // from watch → output, so they can't be the same place. We compare on
        // the *bookmark data* level: any difference (including the same
        // folder picked twice via different bookmarks) is treated as fine
        // here and ultimately caught at folder-resolve time in Phase 2.
        if let watch = watchFolderBookmark,
           let output = outputFolderBookmark,
           watch == output {
            issues.append(.watchAndOutputFoldersIdentical)
        }

        return issues
    }
}
