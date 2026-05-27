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

    private var running = false
    private var consumerTask: Task<Void, Never>?

    init(
        config: PipelineConfig,
        watcher: FolderWatcher,
        transcriptionClient: TranscriptionClient = TranscriptionClient(),
        fileOrganizer: FileOrganizer = FileOrganizer(),
        onStateChange: @escaping @Sendable (PipelineState) -> Void,
        onAuditEntry: @escaping @Sendable (AuditLogEntry) -> Void
    ) {
        self.config = config
        self.watcher = watcher
        self.transcriptionClient = transcriptionClient
        self.fileOrganizer = fileOrganizer
        self.onStateChange = onStateChange
        self.onAuditEntry = onAuditEntry
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

        do {
            // 1. Transcribe.
            let transcript = try await transcriptionClient.transcribe(
                audio: url,
                baseURL: config.apiBaseURL,
                model: config.model,
                apiKey: config.apiKey
            )

            // 2. Organize: per-meeting folder + transcript + move audio.
            let meetingFolder = try await fileOrganizer.organize(
                audio: url,
                transcript: transcript,
                outputRoot: config.outputFolder
            )

            // 3. Success — clear watcher state for this path so the user can
            // drop a new file at the same path and have it picked up. The
            // ledger entry was the right call while the file was still
            // sitting in the Watch Folder (prevents double-processing on a
            // relaunch), but now the file has been moved out and the entry
            // is moot.
            await watcher.forget(url)

            // 4. Log + reset state.
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            onAuditEntry(.init(
                kind: .success,
                sourcePath: url.path(percentEncoded: false),
                message: "Transcribed and filed → \(meetingFolder.lastPathComponent)",
                durationMs: ms,
                retryable: false
            ))
            onStateChange(.idle)

        } catch let error as TranscriptionError {
            recordFailure(url: url, message: error.userFacingMessage, startedAt: startTime)
        } catch let error as FileOrganizerError {
            recordFailure(url: url, message: error.userFacingMessage, startedAt: startTime)
        } catch is CancellationError {
            // Shutdown happened mid-flight — don't log as failure.
            return
        } catch {
            recordFailure(url: url, message: error.localizedDescription, startedAt: startTime)
        }
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
