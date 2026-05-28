import Foundation

/// Snapshot of all settings the pipeline needs to actually run. Captured
/// once at start time so the pipeline doesn't have to reach back into
/// `AppSettings` on every file. If the user changes a setting, the
/// coordinator stops this pipeline and creates a new one with a fresh
/// snapshot.
struct PipelineConfig: Sendable, Equatable {
    let watchFolder: URL
    let outputFolder: URL
    let apiBaseURL: URL
    let model: String
    let apiKey: String

    init(
        watchFolder: URL,
        outputFolder: URL,
        apiBaseURL: URL,
        model: String,
        apiKey: String
    ) {
        self.watchFolder = watchFolder
        self.outputFolder = outputFolder
        self.apiBaseURL = apiBaseURL
        self.model = model
        self.apiKey = apiKey
    }
}

/// Orchestrates the watch → transcribe → organize flow.
///
/// Runs as an `actor` so its mutable state (current file, queue) is
/// serialized without locks. Files are processed strictly one at a time —
/// the Whisper endpoints are rate-limited and a serial queue makes the
/// menu-bar icon's `PipelineState` trivial to reason about.
///
/// State updates and audit log writes happen on `@MainActor` via hops.
actor ProcessingPipeline {

    private let config: PipelineConfig
    private let watcher: FolderWatcher
    private let transcriptionClient: TranscriptionClient
    private let fileOrganizer: FileOrganizer

    /// Closures that hop to `@MainActor` to update UI state. Injected so the
    /// pipeline doesn't have to know about `AppSettings` or `MenuBarController`
    /// or `AuditLogStore` directly.
    private let onStateChange: @Sendable (PipelineState) -> Void
    private let onAuditEntry: @Sendable (AuditLogEntry) -> Void

    /// Optional bridge to `MeetingContextStore`. Given a file's creation
    /// date, returns the full snapshot for the recording Jot kicked off —
    /// but only if that creation date is plausibly inside Jot's recording
    /// window (see `MeetingContextStore` for the time-window check). Nil
    /// for tests / harnesses that don't care about renaming or context.
    ///
    /// Phase D uses only `snapshot.meetingName` (for rename); Phase F adds
    /// the prompt-compile + send step using the same snapshot.
    private let consumeMeetingContext: (@Sendable (Date) async -> MeetingContextSnapshot?)?

    private var running = false
    private var consumerTask: Task<Void, Never>?

    init(
        config: PipelineConfig,
        watcher: FolderWatcher,
        transcriptionClient: TranscriptionClient = TranscriptionClient(),
        fileOrganizer: FileOrganizer = FileOrganizer(),
        onStateChange: @escaping @Sendable (PipelineState) -> Void,
        onAuditEntry: @escaping @Sendable (AuditLogEntry) -> Void,
        consumeMeetingContext: (@Sendable (Date) async -> MeetingContextSnapshot?)? = nil
    ) {
        self.config = config
        self.watcher = watcher
        self.transcriptionClient = transcriptionClient
        self.fileOrganizer = fileOrganizer
        self.onStateChange = onStateChange
        self.onAuditEntry = onAuditEntry
        self.consumeMeetingContext = consumeMeetingContext
    }

    // MARK: - Lifecycle

    /// Start the watcher and begin consuming its stream. Idempotent — a
    /// second call is a no-op.
    func start() async throws {
        if running { return }
        running = true

        let stream = try await watcher.start()
        onStateChange(.idle)
        onAuditEntry(.init(
            kind: .info,
            sourcePath: config.watchFolder.path(percentEncoded: false),
            message: "Pipeline started — watching \(config.watchFolder.lastPathComponent)"
        ))

        consumerTask = Task { [weak self] in
            for await url in stream {
                await self?.process(url: url)
            }
            await self?.handleStreamEnd()
        }
    }

    /// Stop the watcher and tear down. After this the pipeline can't be
    /// restarted — create a fresh instance for a restart.
    func stop() async {
        if !running { return }
        running = false
        consumerTask?.cancel()
        consumerTask = nil
        await watcher.stop()
        onStateChange(.notConfigured)
    }

    /// Re-process a file the user clicked Retry on. The file is still in the
    /// Watch Folder (Pipeline only moves successful runs out), so we just
    /// call into `process(url:)` directly.
    func retry(url: URL) async {
        guard running else { return }
        await process(url: url)
    }

    // MARK: - Per-file processing

    private func process(url: URL) async {
        let startTime = Date()
        onStateChange(.processing(url))

        // 0. If this file's creation date falls inside an active Jot-driven
        // recording window, rename it to the meeting name the user typed.
        // The watcher hands us timestamp-named files from AH regardless of
        // who started the session — the time-window guard in
        // `MeetingNameStore` ensures we only rename files we know are ours.
        // Best-effort: a failed rename falls back to the original URL so
        // transcription still happens.
        let workingURL = await renameIfMeetingNamePending(url) ?? url

        do {
            // 1. Transcribe.
            let transcript = try await transcriptionClient.transcribe(
                audio: workingURL,
                baseURL: config.apiBaseURL,
                model: config.model,
                apiKey: config.apiKey
            )

            // 2. Organize: per-meeting folder + transcript + move audio.
            let meetingFolder = try await fileOrganizer.organize(
                audio: workingURL,
                transcript: transcript,
                outputRoot: config.outputFolder
            )

            // 3. Success — clear watcher state for this path so the user can
            // drop a new file at the same path and have it picked up. The
            // ledger entry was the right call while the file was still
            // sitting in the Watch Folder (prevents double-processing on a
            // relaunch), but now the file has been moved out and the entry
            // is moot.
            await watcher.forget(workingURL)

            // 4. Log + reset state.
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            onAuditEntry(.init(
                kind: .success,
                sourcePath: workingURL.path(percentEncoded: false),
                message: "Transcribed and filed → \(meetingFolder.lastPathComponent)",
                durationMs: ms,
                retryable: false
            ))
            onStateChange(.idle)

        } catch let error as TranscriptionError {
            recordFailure(url: workingURL, message: error.userFacingMessage, startedAt: startTime)
        } catch let error as FileOrganizerError {
            recordFailure(url: workingURL, message: error.userFacingMessage, startedAt: startTime)
        } catch is CancellationError {
            // Shutdown happened mid-flight — don't log as failure.
            return
        } catch {
            recordFailure(url: workingURL, message: error.localizedDescription, startedAt: startTime)
        }
    }

    /// Try to rename `url` to the meeting name the user typed at the start
    /// prompt. Returns the new URL on success, or nil if no rename happened
    /// (no pending meeting, creation date outside the window, sanitized name
    /// empty, or the actual `moveItem` failed). Never throws — rename is
    /// strictly best-effort and must not block transcription.
    private func renameIfMeetingNamePending(_ url: URL) async -> URL? {
        guard let consume = consumeMeetingContext else { return nil }
        guard let creationDate = fileCreationDate(of: url) else { return nil }
        guard let snapshot = await consume(creationDate) else { return nil }
        guard let safeName = MeetingContextStore.sanitizedFilenameComponent(snapshot.meetingName) else { return nil }

        let parent = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let target = uniqueAudioURL(under: parent, baseName: safeName, ext: ext)

        // Pre-register the new path in the ledger so the FS event the move
        // triggers doesn't cause the watcher to re-emit the file. The
        // detector also needs `stableDuration` of unchanged state before
        // it'd emit anyway, so this is belt-and-braces.
        await watcher.preRecord(target)
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            // Rollback the pre-registration so a future legitimately-new
            // file at this path can still be picked up.
            await watcher.forget(target)
            Log.pipeline.warning("Meeting-name rename failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Old path is gone. Drop its ledger + detector entries so we don't
        // hold a stale record across restarts.
        await watcher.forget(url)

        onAuditEntry(.init(
            kind: .info,
            sourcePath: target.path(percentEncoded: false),
            message: "Renamed \(url.lastPathComponent) → \(target.lastPathComponent) (meeting name)"
        ))
        Log.pipeline.info("Renamed \(url.lastPathComponent, privacy: .public) → \(target.lastPathComponent, privacy: .public)")
        return target
    }

    /// Inode creation timestamp via `URLResourceValues`. Approximates when
    /// Audio Hijack opened the file for writing — i.e., when recording
    /// began — which is exactly what `MeetingContextStore` wants to compare
    /// against its `startedAt`.
    private func fileCreationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey])
        return values?.creationDate
    }

    /// Pick a free URL of the form `<parent>/<baseName>.<ext>`, suffixing
    /// `-2`, `-3`, … on collision. Mirrors `FileOrganizer.uniqueFolderURL`
    /// — same shape, same fallback, applied to files rather than folders.
    private func uniqueAudioURL(under parent: URL, baseName: String, ext: String) -> URL {
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"
        let direct = parent.appendingPathComponent("\(baseName)\(extSuffix)")
        if !FileManager.default.fileExists(atPath: direct.path(percentEncoded: false)) {
            return direct
        }
        for suffix in 2...999 {
            let candidate = parent.appendingPathComponent("\(baseName)-\(suffix)\(extSuffix)")
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return parent.appendingPathComponent("\(baseName)-\(UUID().uuidString.prefix(8))\(extSuffix)")
    }

    private func recordFailure(url: URL, message: String, startedAt: Date) {
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        onAuditEntry(.init(
            kind: .failure,
            sourcePath: url.path(percentEncoded: false),
            message: message,
            durationMs: ms,
            retryable: true
        ))
        // PRD §4.3: failed files must stay in the Watch Folder. We don't
        // touch the source on failure — `FileOrganizer` only moves on
        // success, and we never delete from the Watch Folder ourselves.
        onStateChange(.error(url, message))
        Log.pipeline.error("Processing failed for \(url.lastPathComponent, privacy: .public): \(message, privacy: .public)")
    }

    private func handleStreamEnd() {
        // Watcher's stream finished (we called stop, or the folder went away).
        if running {
            onStateChange(.error(config.watchFolder, "Watch folder became unreachable"))
        }
    }
}
