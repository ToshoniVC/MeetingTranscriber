import AppKit
import Foundation
import Observation

/// Where the manual-upload flow is in its lifecycle. Surfaced to the
/// Transcripts view so the upload button can disable itself + show a
/// progress label without us threading callbacks back manually.
enum ManualUploadStatus: Equatable, Sendable {
    case idle
    case collectingMetadata
    case converting(filename: String)
    case staging(filename: String)
    case failed(message: String)

    /// True when the coordinator is actively doing work for an in-flight
    /// upload. Drives the upload button's `.disabled(...)` modifier so
    /// the user can't kick off a second upload that would race against
    /// the in-flight one (the `MeetingContextStore.pending` slot only
    /// holds one snapshot).
    var isBusy: Bool {
        switch self {
        case .idle, .failed: return false
        case .collectingMetadata, .converting, .staging: return true
        }
    }
}

/// Orchestrates the manual-upload flow from the user clicking "Upload
/// Recording…" to the file(s) landing in the Watch Folder ready for the
/// `FolderWatcher` to pick them up.
///
/// **Pipeline integration.** This coordinator deliberately does *not*
/// know about `ProcessingPipeline`. It stamps either
/// `MeetingContextStore` (single-file path) or
/// `MeetingBatchAccumulator` (multi-file path, v0.5.1+) with the
/// user-provided metadata and drops the (converted, if needed) file
/// into the Watch Folder. The existing watcher → pipeline path treats
/// it as if Audio Hijack had just produced a recording: the same
/// `consume`/`peek` calls attach the snapshot, the same rename applies
/// the meeting name, the same transcription / Notion / Claude Code
/// chain runs. Multi-file uploads bypass the single-file
/// `consumeMeetingContext` path entirely by going through the batch
/// accumulator, which the pipeline already understands.
///
/// **Ledger interplay (v0.5.1).** Before each stage we explicitly
/// `forget` the target path from the watcher's `ProcessedFilesLedger`.
/// That way a previous failed attempt at the same path — which would
/// otherwise leave the watcher silently skipping the new copy — can't
/// block the re-upload. Without this, re-uploading a meeting that
/// failed once would just see "Manual upload: staged" with no
/// transcription downstream, which was the v0.5.0 bug report.
///
/// **Serialization.** The flow is single-threaded by virtue of
/// `@MainActor`. The Upload button is disabled while `status.isBusy`,
/// so a second upload can't start until the staging step for the
/// previous one returns. Concurrent uploads aren't supported.
@MainActor
@Observable
final class ManualUploadCoordinator {

    private let settings: AppSettings
    private let auditLog: AuditLogStore
    private let organizations: OrganizationStore
    private let meetingContextStore: MeetingContextStore
    private let batchAccumulator: MeetingBatchAccumulator?
    private let processedFilesLedger: ProcessedFilesLedger?
    private let prompter: any MeetingUploadPrompting
    private let staging: ManualUploadStagingService
    private let conversion: MediaConversionService
    private let filePicker: ManualUploadFilePicking
    private let watchFolderResolver: @MainActor () -> URL?

    /// Current state of the upload flow. Read by `TranscriptsView` to
    /// drive the button's enabled state and the progress label.
    private(set) var status: ManualUploadStatus = .idle

    init(
        settings: AppSettings,
        auditLog: AuditLogStore,
        organizations: OrganizationStore,
        meetingContextStore: MeetingContextStore,
        batchAccumulator: MeetingBatchAccumulator? = nil,
        processedFilesLedger: ProcessedFilesLedger? = nil,
        prompter: (any MeetingUploadPrompting)? = nil,
        staging: ManualUploadStagingService = ManualUploadStagingService(),
        conversion: MediaConversionService = MediaConversionService(),
        filePicker: ManualUploadFilePicking? = nil,
        watchFolderResolver: (@MainActor () -> URL?)? = nil
    ) {
        self.settings = settings
        self.auditLog = auditLog
        self.organizations = organizations
        self.meetingContextStore = meetingContextStore
        self.batchAccumulator = batchAccumulator
        self.processedFilesLedger = processedFilesLedger
        // Default UI dependencies are instantiated inside the init body
        // (not as parameter defaults) because Swift treats default
        // parameter expressions as nonisolated, which would refuse to
        // call these `@MainActor`-isolated initializers.
        self.prompter = prompter ?? SystemMeetingUploadPrompter()
        self.staging = staging
        self.conversion = conversion
        self.filePicker = filePicker ?? SystemManualUploadFilePicker()
        // Default resolver pulls the bookmark from settings; tests inject
        // a closure that returns a tmpdir directly so they don't need to
        // round-trip through security-scoped bookmark creation (which
        // doesn't work cleanly outside an actual sandboxed UI gesture).
        self.watchFolderResolver = watchFolderResolver ?? { [settings] in
            guard let data = settings.watchFolderBookmark else { return nil }
            var isStale = false
            return try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
    }

    /// Dismiss a `.failed(...)` status. Called when the user closes the
    /// upload error alert in `TranscriptsView`. No-op for any other
    /// state so it's safe to wire to an `.onDismiss` indiscriminately.
    func dismissFailure() {
        if case .failed = status {
            status = .idle
        }
    }

    /// Entry point: invoked by the "Upload Recording…" button. Shows
    /// the file picker, collects metadata, performs conversion if
    /// needed, and stages the file(s) into the Watch Folder. Returns
    /// silently — outcomes are surfaced via `status` and the audit log.
    func beginUpload() async {
        guard !status.isBusy else { return }
        do {
            try await runUpload()
            status = .idle
        } catch let error as ManualUploadError {
            if case .userCancelled = error {
                status = .idle
                return
            }
            status = .failed(message: error.userFacingMessage)
            auditLog.append(.init(
                kind: .failure,
                sourcePath: "ManualUpload",
                message: error.userFacingMessage
            ))
            Log.manualUpload.error("Manual upload failed: \(error.userFacingMessage, privacy: .public)")
        } catch {
            status = .failed(message: error.localizedDescription)
            auditLog.append(.init(
                kind: .failure,
                sourcePath: "ManualUpload",
                message: error.localizedDescription
            ))
            Log.manualUpload.error("Manual upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Flow

    private func runUpload() async throws {
        // 1. Resolve the Watch Folder up front so we can fail fast
        // before bothering the user with a picker.
        guard let watchFolder = resolveWatchFolder() else {
            throw ManualUploadError.watchFolderUnreachable
        }

        // 2. Pick source file(s).
        let sources = await filePicker.pick()
        guard !sources.isEmpty else {
            throw ManualUploadError.userCancelled
        }

        // 3. Validate every selection up front. Aborting early on a
        // single bad file is friendlier than staging some-then-failing
        // and leaving partial state in the Watch Folder.
        var validated: [(url: URL, kind: ManualUploadMediaKind)] = []
        for source in sources {
            let kind = try staging.validate(source)
            validated.append((source, kind))
        }

        let displaySource = sources[0].lastPathComponent
        let description: String
        if sources.count == 1 {
            description = displaySource
        } else {
            description = "\(displaySource) + \(sources.count - 1) more (one meeting)"
        }
        auditLog.append(.init(
            kind: .info,
            sourcePath: sources[0].path(percentEncoded: false),
            message: sources.count == 1
                ? "Manual upload: selected \(displaySource)"
                : "Manual upload: selected \(sources.count) files for one meeting (\(displaySource), …)"
        ))
        Log.manualUpload.info("Picked \(sources.count, privacy: .public) file(s); first: \(displaySource, privacy: .public)")

        // 4. Collect metadata once for the whole upload.
        status = .collectingMetadata
        let inputs = await prompter.askForUpload(
            sourceDescription: description,
            organizations: organizations.organizations,
            defaultOrgId: organizations.defaultOrg()?.id
        )
        guard let inputs else {
            throw ManualUploadError.userCancelled
        }
        let trimmedName = inputs.meetingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ManualUploadError.invalidMeetingName
        }

        // 5. Compile the snapshot the pipeline will see.
        let startedAt = Date()
        let organization = inputs.organizationId.flatMap { organizations.organization(id: $0) }
        let compiledContext = ContextCompiler.compile(
            meetingName: trimmedName,
            meetingSpecificContext: inputs.meetingSpecificContext,
            organization: organization
        )
        let snapshot = MeetingContextSnapshot(
            meetingName: trimmedName,
            organizationId: inputs.organizationId,
            organizationName: organization?.name,
            meetingSpecificContext: inputs.meetingSpecificContext,
            resolvedCompiledContext: compiledContext,
            lastEditedAt: startedAt
        )

        // 6. Dispatch to the right path. Multi-file goes through the
        // batch accumulator so all parts merge into one Notion page +
        // one meeting folder. Single-file keeps the v0.5.0 flow via
        // `MeetingContextStore` so the pipeline's `consume` lookup
        // still works.
        let didStartScope = watchFolder.startAccessingSecurityScopedResource()
        defer { if didStartScope { watchFolder.stopAccessingSecurityScopedResource() } }

        if sources.count == 1, let only = validated.first {
            try await runSingle(
                source: only.url,
                kind: only.kind,
                snapshot: snapshot,
                startedAt: startedAt,
                watchFolder: watchFolder,
                organization: organization,
                trimmedName: trimmedName
            )
        } else {
            try await runMultiple(
                sources: validated,
                snapshot: snapshot,
                startedAt: startedAt,
                watchFolder: watchFolder,
                organization: organization,
                trimmedName: trimmedName
            )
        }
    }

    // MARK: - Pre-staging conversion (v0.5.4 normalises MP3s)

    /// Decide whether `source` needs conversion to m4a before staging.
    ///
    /// - `mp4` always needs extraction (the file is a video container).
    /// - `mp3` needs re-encoding because Audio Hijack split parts can
    ///   have ID3/Xing metadata that Whisper's server-side decoder
    ///   rejects even when local decoders handle them (the v0.5.2
    ///   `"The audio file could not be decoded or its format is not
    ///   supported"` 400 surface). Re-encoding to AAC in an m4a
    ///   container via `MediaConversionService` produces a clean file
    ///   every endpoint accepts.
    /// - `m4a` and `wav` pass through — they're already cleanly
    ///   decodable, and re-encoding would just waste time + fidelity.
    ///
    /// `nonisolated` + static so the routing decision is unit-testable
    /// without standing up the coordinator.
    nonisolated static func needsNormalization(
        kind: ManualUploadMediaKind,
        extension ext: String
    ) -> Bool {
        switch (kind, ext.lowercased()) {
        case (.videoMP4, _): return true
        case (.audio, "mp3"): return true
        case (.audio, _): return false
        }
    }

    /// If `source` needs normalisation per `needsNormalization`, run
    /// the conversion and return the temp m4a URL (+ the same URL as
    /// the temp artefact the caller must clean up). Otherwise return
    /// the source unchanged and a nil temp artefact.
    private func prepareStagingSource(
        for source: URL,
        kind: ManualUploadMediaKind
    ) async throws -> (stagingSource: URL, tempArtifact: URL?) {
        guard Self.needsNormalization(kind: kind, extension: source.pathExtension) else {
            return (source, nil)
        }
        status = .converting(filename: source.lastPathComponent)
        let tempURL = tempOutputURL(for: source, ext: "m4a")
        try await conversion.extractAudio(from: source, to: tempURL)
        let action = (kind == .videoMP4) ? "extracted audio" : "normalized MP3"
        auditLog.append(.init(
            kind: .info,
            sourcePath: source.path(percentEncoded: false),
            message: "Manual upload: \(action) from \(source.lastPathComponent)"
        ))
        Log.manualUpload.info("\(action, privacy: .public): \(source.lastPathComponent, privacy: .public)")
        return (tempURL, tempURL)
    }

    // MARK: - Single-file path (v0.5.0)

    private func runSingle(
        source: URL,
        kind: ManualUploadMediaKind,
        snapshot: MeetingContextSnapshot,
        startedAt: Date,
        watchFolder: URL,
        organization: Organization?,
        trimmedName: String
    ) async throws {
        // Open the single-file context window the pipeline's
        // `consumeMeetingContext` (legacy path) reads from.
        meetingContextStore.recordStarted(
            meetingName: snapshot.meetingName,
            organizationId: snapshot.organizationId,
            organizationName: snapshot.organizationName,
            meetingSpecificContext: snapshot.meetingSpecificContext,
            resolvedCompiledContext: snapshot.resolvedCompiledContext,
            at: startedAt
        )

        // Conversion step: mp4 → extract audio, mp3 → normalise (v0.5.4
        // to dodge Whisper-server "could not decode" 400s on Audio
        // Hijack split MP3s), m4a/wav → passthrough.
        let stagingSource: URL
        var tempArtifact: URL?
        do {
            (stagingSource, tempArtifact) = try await prepareStagingSource(
                for: source, kind: kind
            )
        } catch {
            meetingContextStore.reset()
            throw error
        }

        // Stage (clears ledger entry first to defeat the v0.5.0 "re-
        // upload silently skipped" bug).
        status = .staging(filename: source.lastPathComponent)
        let staged: URL
        do {
            staged = try await stageOne(source: stagingSource, into: watchFolder)
        } catch {
            if let tempArtifact { try? FileManager.default.removeItem(at: tempArtifact) }
            meetingContextStore.reset()
            throw error
        }
        if let tempArtifact { try? FileManager.default.removeItem(at: tempArtifact) }

        meetingContextStore.recordStopped(at: Date())

        auditLog.append(.init(
            kind: .info,
            sourcePath: staged.path(percentEncoded: false),
            message: "Manual upload: staged into Watch Folder — '\(trimmedName)'\(organization.map { " · \($0.name)" } ?? "")"
        ))
        Log.manualUpload.info("Staged → \(staged.lastPathComponent, privacy: .public)")
    }

    // MARK: - Multi-file path (v0.5.1)

    private func runMultiple(
        sources: [(url: URL, kind: ManualUploadMediaKind)],
        snapshot: MeetingContextSnapshot,
        startedAt: Date,
        watchFolder: URL,
        organization: Organization?,
        trimmedName: String
    ) async throws {
        guard let accumulator = batchAccumulator else {
            // Without a batch accumulator we can't combine the parts
            // into one meeting. Refuse rather than silently producing
            // N independent meetings, which would surprise the user
            // who explicitly multi-selected.
            throw ManualUploadError.stagingFailed(
                "Multi-file upload requires the batch accumulator to be wired (this build doesn't have one)."
            )
        }

        // Open the batch session before any file lands in the Watch
        // Folder. The accumulator's window starts at `startedAt` and
        // closes when we call `noteRecordingStopped` after the last
        // stage — every staged file's creationDate is bumped to "now"
        // inside `stageOne`, so they all fall inside the window and
        // get buffered together.
        await accumulator.noteRecordingStarted(snapshot: snapshot, at: startedAt)

        var stagedURLs: [URL] = []
        var tempArtifacts: [URL] = []

        do {
            for entry in sources {
                let (stagingSource, tempArtifact) = try await prepareStagingSource(
                    for: entry.url, kind: entry.kind
                )
                if let tempArtifact { tempArtifacts.append(tempArtifact) }

                status = .staging(filename: entry.url.lastPathComponent)
                let staged = try await stageOne(source: stagingSource, into: watchFolder)
                stagedURLs.append(staged)
            }
        } catch {
            // On partial failure: undo what we staged + reset
            // accumulator session so the user can retry cleanly.
            for staged in stagedURLs {
                try? FileManager.default.removeItem(at: staged)
            }
            for temp in tempArtifacts {
                try? FileManager.default.removeItem(at: temp)
            }
            await accumulator.noteRecordingStopped(at: Date())
            // The accumulator's `flushNow` will be triggered by the
            // settle timer with zero parts (we just removed them), so
            // it'll no-op cleanly. We don't directly call `stop()` —
            // the accumulator is shared with the pipeline.
            throw error
        }

        // Clean up MP4 conversion temps now that all stagings are done.
        for temp in tempArtifacts {
            try? FileManager.default.removeItem(at: temp)
        }

        // Close the batch window. The accumulator will buffer everything
        // it ingested between `noteRecordingStarted` and now, then flush
        // as a `.batch` after the settle delay.
        await accumulator.noteRecordingStopped(at: Date())

        auditLog.append(.init(
            kind: .info,
            sourcePath: stagedURLs.first?.path(percentEncoded: false) ?? "ManualUpload",
            message: "Manual upload: staged \(stagedURLs.count) parts into Watch Folder — '\(trimmedName)'\(organization.map { " · \($0.name)" } ?? "")"
        ))
        Log.manualUpload.info("Staged \(stagedURLs.count, privacy: .public) parts → batch path")
    }

    // MARK: - Staging helper

    /// Stage one source file, doing the ledger cleanup + post-copy
    /// creationDate bump that both paths share.
    ///
    /// - Clears any stale `ProcessedFilesLedger` entry for the target
    ///   path so a previous failed attempt doesn't cause the watcher
    ///   to silently skip the new copy (the v0.5.0 re-upload bug).
    /// - After copying, overwrites the destination's `creationDate` to
    ///   `now`. Without this, `FileManager.copyItem` preserves the
    ///   source's attributes — including a creation date that may be
    ///   hours/days old — which the `MeetingBatchAccumulator` window
    ///   check rejects ("not inside our recording window"). Bumping
    ///   the date keeps every staged file inside whichever session
    ///   window the caller has open.
    private func stageOne(source: URL, into watchFolder: URL) async throws -> URL {
        // Pre-compute the target so we can clear its ledger entry
        // *before* the watcher sees the file. The staging service's
        // uniqueURL gives us the same destination it'd pick.
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let target = staging.uniqueURL(under: watchFolder, baseName: baseName, ext: ext)

        if let ledger = processedFilesLedger {
            try? await ledger.forget(target)
        }

        // The staging service does the actual copy. It re-checks the
        // target on its own to be safe against a race where the watch
        // folder filled up between our uniqueURL call and the copy.
        let staged = try staging.stage(source: source, into: watchFolder)

        // Overwrite creationDate so the accumulator's window check
        // accepts the file as "part of the recording we just opened."
        var resourceValues = URLResourceValues()
        resourceValues.creationDate = Date()
        var mutable = staged
        try? mutable.setResourceValues(resourceValues)

        return staged
    }

    // MARK: - Helpers

    private func resolveWatchFolder() -> URL? {
        watchFolderResolver()
    }

    private func tempOutputURL(for source: URL, ext: String) -> URL {
        let baseName = source.deletingPathExtension().lastPathComponent
        let unique = "\(baseName)-\(UUID().uuidString.prefix(8)).\(ext)"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(unique)
    }
}
