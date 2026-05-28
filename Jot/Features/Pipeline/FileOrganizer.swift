import Foundation

/// Errors thrown by `FileOrganizer`. Each carries a `userFacingMessage` so the
/// Audit Log can surface what went wrong without parsing strings.
enum FileOrganizerError: Error, Equatable {
    case audioFileMissing(URL)
    case outputFolderUnreachable(URL)
    case writeTranscriptFailed(String)
    case moveAudioFailed(String)
    case rollbackFailed(String)

    var userFacingMessage: String {
        switch self {
        case .audioFileMissing(let url):
            return "Source audio file missing at \(url.lastPathComponent)."
        case .outputFolderUnreachable(let url):
            return "Output folder unreachable: \(url.path(percentEncoded: false))."
        case .writeTranscriptFailed(let message):
            return "Couldn't write transcript: \(message)."
        case .moveAudioFailed(let message):
            return "Couldn't move source audio: \(message)."
        case .rollbackFailed(let message):
            return "Cleanup after a failed organize() also failed: \(message)."
        }
    }
}

/// Lays down the per-meeting folder structure required by PRD §4.2:
///   `<outputRoot>/<meetingName>/<meetingName>.{mp3|m4a|wav}` (moved here)
///   `<outputRoot>/<meetingName>/<meetingName>.txt`            (just written)
///
/// Where `meetingName = sourceURL.deletingPathExtension().lastPathComponent`
/// (e.g., `2026-05-27_14-24_Client_Call.mp3` → `2026-05-27_14-24_Client_Call`).
///
/// The Watch Folder ends empty for this file — the source audio is *moved*,
/// not copied (PRD §4.2: "Ensure no residual data remains in the Watch Folder").
///
/// If `<meetingName>/` already exists in the Output Folder, we append `-2`,
/// `-3`, … until we find a free name. Never overwrite.
///
/// **Rollback contract.** If the audio move fails *after* the transcript has
/// already been written, we delete the transcript and the (empty) meeting
/// folder so we don't leave a half-state. The original audio file stays put
/// in the Watch Folder (so retry works).
struct FileOrganizer: Sendable {

    /// Inject a custom `FileManager` for tests that want to simulate I/O
    /// failures or operate in a hermetic temp dir. Production uses `.default`.
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Organize a successfully-transcribed file into its meeting folder.
    /// Thin wrapper around the multi-part path — kept so legacy callers
    /// (single-file pipeline path, tests) don't have to change.
    @discardableResult
    func organize(
        audio sourceURL: URL,
        transcript: String,
        context: String? = nil,
        outputRoot: URL
    ) async throws -> URL {
        try await organize(
            audioParts: [sourceURL],
            transcript: transcript,
            context: context,
            outputRoot: outputRoot
        )
    }

    /// Organize a successfully-transcribed meeting into its folder. Handles
    /// both the single-file case (one URL in `audioParts`) and the
    /// split-recording case (Audio Hijack's "split at X MB" produced
    /// multiple parts that all belong to one meeting).
    ///
    /// - Parameters:
    ///   - audioParts: source audio URLs in playback order. The first
    ///     part's basename names the meeting folder + transcript. All
    ///     parts are moved into the new folder under their existing
    ///     filenames.
    ///   - transcript: the combined transcript (caller concatenates per-part
    ///     transcripts upstream — `FileOrganizer` is dumb about ordering).
    ///   - outputRoot: the user-chosen Output Folder (already-resolved URL).
    ///     Caller is responsible for `startAccessingSecurityScopedResource()`.
    /// - Returns: the absolute URL of the meeting folder just created.
    ///
    /// **Rollback contract.** If *any* audio move fails after the transcript
    /// has been written, we move any already-moved parts back to their
    /// original locations, delete the transcript + context.md, and remove
    /// the (now-empty) folder. The original audio files stay in the Watch
    /// Folder so the user can retry.
    @discardableResult
    func organize(
        audioParts: [URL],
        transcript: String,
        context: String? = nil,
        outputRoot: URL
    ) async throws -> URL {
        // 1. Validate inputs.
        guard let firstPart = audioParts.first else {
            throw FileOrganizerError.audioFileMissing(outputRoot)
        }
        for part in audioParts {
            guard fileManager.fileExists(atPath: part.path(percentEncoded: false)) else {
                throw FileOrganizerError.audioFileMissing(part)
            }
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: outputRoot.path(percentEncoded: false), isDirectory: &isDir),
              isDir.boolValue
        else {
            throw FileOrganizerError.outputFolderUnreachable(outputRoot)
        }

        // 2. Pick the meeting folder URL (with collision suffix if needed).
        let baseName = firstPart.deletingPathExtension().lastPathComponent
        let meetingFolder = uniqueFolderURL(under: outputRoot, baseName: baseName)

        // 3. Create the meeting folder.
        do {
            try fileManager.createDirectory(at: meetingFolder, withIntermediateDirectories: false)
        } catch {
            throw FileOrganizerError.outputFolderUnreachable(meetingFolder)
        }

        // 4a. Write the transcript next to where the audio will land.
        let transcriptURL = meetingFolder.appendingPathComponent("\(baseName).txt")
        do {
            try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        } catch {
            try? fileManager.removeItem(at: meetingFolder)
            throw FileOrganizerError.writeTranscriptFailed(error.localizedDescription)
        }

        // 4b. Optionally write context.md alongside the transcript — the
        // exact compiled prompt that was sent to Whisper, for
        // reproducibility (PRD §8). Best-effort: a failed context write
        // doesn't roll back the transcript, since the transcript itself
        // is still valuable on its own.
        let contextURL = meetingFolder.appendingPathComponent("context.md")
        var contextWritten = false
        if let context, !context.isEmpty {
            let body = "# Transcription context\n\nSent with the audio to the transcription endpoint. Kept here for reproducibility.\n\n```\n\(context)\n```\n"
            do {
                try body.write(to: contextURL, atomically: true, encoding: .utf8)
                contextWritten = true
            } catch {
                Log.pipeline.warning("Couldn't write context.md: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 5. Move each audio part into the meeting folder. On failure of
        // any move, roll back the already-moved parts so the user's Watch
        // Folder ends in the state it started in.
        var movedPairs: [(original: URL, destination: URL)] = []
        for part in audioParts {
            let destination = meetingFolder.appendingPathComponent(part.lastPathComponent)
            do {
                try fileManager.moveItem(at: part, to: destination)
                movedPairs.append((original: part, destination: destination))
            } catch {
                // Roll back: move every already-moved part back to its
                // original Watch Folder location.
                for pair in movedPairs {
                    try? fileManager.moveItem(at: pair.destination, to: pair.original)
                }
                try? fileManager.removeItem(at: transcriptURL)
                if contextWritten {
                    try? fileManager.removeItem(at: contextURL)
                }
                try? fileManager.removeItem(at: meetingFolder)
                throw FileOrganizerError.moveAudioFailed(error.localizedDescription)
            }
        }

        let partsLabel = audioParts.count == 1
            ? firstPart.lastPathComponent
            : "\(audioParts.count) parts (\(firstPart.lastPathComponent), …)"
        Log.pipeline.info("Organized \(partsLabel, privacy: .public) → \(meetingFolder.lastPathComponent, privacy: .public)")
        return meetingFolder
    }

    /// Return a URL under `outputRoot` whose folder name doesn't yet exist.
    /// First tries `<baseName>`, then `<baseName>-2`, `<baseName>-3`, … up to
    /// 999. After that we give up and stamp with a UUID suffix — the
    /// expected failure mode is "user's filesystem is mad at us", not "we
    /// have 999 meetings with identical names."
    func uniqueFolderURL(under outputRoot: URL, baseName: String) -> URL {
        let direct = outputRoot.appendingPathComponent(baseName, isDirectory: true)
        if !fileManager.fileExists(atPath: direct.path(percentEncoded: false)) {
            return direct
        }
        for suffix in 2...999 {
            let candidate = outputRoot.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return outputRoot.appendingPathComponent("\(baseName)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }
}
