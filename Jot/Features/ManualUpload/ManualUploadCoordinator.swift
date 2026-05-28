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
/// Recording…" to the file landing in the Watch Folder ready for the
/// `FolderWatcher` to pick it up.
///
/// **Pipeline integration.** This coordinator deliberately does *not*
/// know about `ProcessingPipeline`. It stamps `MeetingContextStore` with
/// the user-provided metadata and drops the (converted, if needed) file
/// into the Watch Folder. The existing watcher → pipeline path treats it
/// as if Audio Hijack had just produced a recording: the same
/// `consumeMeetingContext` call attaches the snapshot, the same rename
/// applies the meeting name, the same transcription / Notion / Claude
/// Code chain runs. No new pipeline entry point, no new audit-log
/// schema — the upload feature reuses everything downstream of the
/// watcher's `AsyncStream`.
///
/// **Serialization.** The flow is single-threaded by virtue of
/// `@MainActor`. The Upload button is disabled while `status.isBusy`,
/// so a second upload can't start until the staging step for the
/// previous one returns. That keeps the `pending` slot single-valued.
/// Concurrent uploads aren't supported in this phase.
@MainActor
@Observable
final class ManualUploadCoordinator {

    private let settings: AppSettings
    private let auditLog: AuditLogStore
    private let organizations: OrganizationStore
    private let meetingContextStore: MeetingContextStore
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
    /// needed, and stages the file into the Watch Folder. Returns
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

        // 2. Pick a source file.
        guard let source = await filePicker.pick() else {
            throw ManualUploadError.userCancelled
        }
        let kind = try staging.validate(source)
        auditLog.append(.init(
            kind: .info,
            sourcePath: source.path(percentEncoded: false),
            message: "Manual upload: selected \(source.lastPathComponent)"
        ))
        Log.manualUpload.info("Picked \(source.lastPathComponent, privacy: .public) (\(String(describing: kind), privacy: .public))")

        // 3. Collect metadata.
        status = .collectingMetadata
        let inputs = await prompter.askForUpload(
            sourceFilename: source.lastPathComponent,
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

        // 4. Stamp the meeting-context window *before* the file lands in
        // the Watch Folder. The watcher debounces for ~2 seconds before
        // emitting, but a small file on a fast disk could in principle
        // be emitted sooner — opening the window early guarantees the
        // pipeline's `consume(forFileCreatedAt:)` lookup succeeds.
        let startedAt = Date()
        let organization = inputs.organizationId.flatMap { organizations.organization(id: $0) }
        let compiledContext = ContextCompiler.compile(
            meetingName: trimmedName,
            meetingSpecificContext: inputs.meetingSpecificContext,
            organization: organization
        )
        meetingContextStore.recordStarted(
            meetingName: trimmedName,
            organizationId: inputs.organizationId,
            organizationName: organization?.name,
            meetingSpecificContext: inputs.meetingSpecificContext,
            resolvedCompiledContext: compiledContext,
            at: startedAt
        )

        // 5. If MP4, extract audio to a temp .m4a first. The temp file
        // lives under FileManager.temporaryDirectory; on success we
        // stage from it, then drop it. On failure we surface the typed
        // error and clear the meeting-context window so a later upload
        // doesn't inherit this attempt's metadata.
        let stagingSource: URL
        var tempArtifact: URL?
        switch kind {
        case .audioMP3:
            stagingSource = source
        case .videoMP4:
            status = .converting(filename: source.lastPathComponent)
            let tempURL = tempOutputURL(for: source, ext: "m4a")
            do {
                try await conversion.extractAudio(from: source, to: tempURL)
            } catch {
                meetingContextStore.reset()
                throw error
            }
            tempArtifact = tempURL
            stagingSource = tempURL
            auditLog.append(.init(
                kind: .info,
                sourcePath: source.path(percentEncoded: false),
                message: "Manual upload: extracted audio from \(source.lastPathComponent)"
            ))
            Log.manualUpload.info("Extracted audio for \(source.lastPathComponent, privacy: .public)")
        }

        // 6. Acquire short-lived security-scoped access to the Watch
        // Folder for the copy. `PipelineCoordinator` already holds a
        // long-lived scope when the pipeline is running, but the
        // coordinator owns its own scope per upload so the flow works
        // even if the pipeline is stopped (e.g. user hasn't finished
        // configuring providers yet).
        status = .staging(filename: source.lastPathComponent)
        let staged: URL
        let didStartScope = watchFolder.startAccessingSecurityScopedResource()
        defer { if didStartScope { watchFolder.stopAccessingSecurityScopedResource() } }
        do {
            staged = try staging.stage(source: stagingSource, into: watchFolder)
        } catch {
            // Roll back temp artifact + the open snapshot window so the
            // user can re-try without inheriting the half-state.
            if let tempArtifact { try? FileManager.default.removeItem(at: tempArtifact) }
            meetingContextStore.reset()
            throw error
        }
        if let tempArtifact { try? FileManager.default.removeItem(at: tempArtifact) }

        // 7. Close the meeting-context window so any *other* file the
        // watcher detects after this upload doesn't accidentally claim
        // these inputs.
        meetingContextStore.recordStopped(at: Date())

        auditLog.append(.init(
            kind: .info,
            sourcePath: staged.path(percentEncoded: false),
            message: "Manual upload: staged into Watch Folder — '\(trimmedName)'\(organization.map { " · \($0.name)" } ?? "")"
        ))
        Log.manualUpload.info("Staged → \(staged.lastPathComponent, privacy: .public)")
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
