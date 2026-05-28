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

/// How the pipeline should treat Notion post-success. Snapshotted at
/// pipeline-start time so a mid-pipeline settings change doesn't change
/// the per-file behavior — the coordinator restarts on any change.
enum NotionPipelineMode: Sendable {
    /// User opted out (toggle off) or the config didn't pass validation.
    /// The success audit entry is written with
    /// `notionStatus = .skipped(reason)` and no network call happens.
    case skip(reason: NotionStatus.SkipReason)

    /// Wire the Notion writer. The pipeline writes the success entry
    /// with `notionStatus = .pending`, fires a `Task` to call the
    /// writer, and surfaces the outcome via `onNotionStatusChange`.
    case attempt(config: NotionConfig, writer: any NotionMeetingWriter)
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

    /// How to handle Notion post-success — either skip with a recorded
    /// reason or attempt the write via the supplied writer. Nil means
    /// the pipeline isn't Notion-aware at all (test harnesses default);
    /// in that case `notionStatus` on entries stays nil.
    private let notionMode: NotionPipelineMode?

    /// Called when an in-flight Notion task resolves — `(entryId, finalStatus)`.
    /// Hosts (the coordinator) update the corresponding audit entry's
    /// `notionStatus` in the store. Ignored when `notionMode == nil`.
    private let onNotionStatusChange: (@Sendable (UUID, NotionStatus) -> Void)?

    private var running = false
    private var consumerTask: Task<Void, Never>?

    /// In-flight Notion tasks, keyed by their meeting-entry id, so we can
    /// cancel them on `stop()` without leaking writes that outlive the
    /// pipeline.
    private var notionTasks: [UUID: Task<Void, Never>] = [:]

    init(
        config: PipelineConfig,
        watcher: FolderWatcher,
        transcriptionClient: TranscriptionClient = TranscriptionClient(),
        fileOrganizer: FileOrganizer = FileOrganizer(),
        onStateChange: @escaping @Sendable (PipelineState) -> Void,
        onAuditEntry: @escaping @Sendable (AuditLogEntry) -> Void,
        consumeMeetingContext: (@Sendable (Date) async -> MeetingContextSnapshot?)? = nil,
        notionMode: NotionPipelineMode? = nil,
        onNotionStatusChange: (@Sendable (UUID, NotionStatus) -> Void)? = nil
    ) {
        self.config = config
        self.watcher = watcher
        self.transcriptionClient = transcriptionClient
        self.fileOrganizer = fileOrganizer
        self.onStateChange = onStateChange
        self.onAuditEntry = onAuditEntry
        self.consumeMeetingContext = consumeMeetingContext
        self.notionMode = notionMode
        self.onNotionStatusChange = onNotionStatusChange
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
        // Cancel any in-flight Notion writes so they don't outlive us.
        // Cancelled tasks deliberately do not emit `onNotionStatusChange`
        // — the meeting itself was already logged as a success; a
        // cancelled Notion write is silent.
        for task in notionTasks.values { task.cancel() }
        notionTasks.removeAll()
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

        // 0a. If this file's creation date falls inside an active Jot-driven
        // recording window, pull the snapshot we'll use for both renaming
        // and the Whisper `prompt` field. The time-window guard inside
        // `MeetingContextStore.consume` ensures we only claim a snapshot
        // for files we know came from a Jot-kicked session.
        let snapshot = await consumeSnapshotForFile(at: url)

        // 0b. Rename to the user-typed meeting name when one is available.
        // Best-effort: a failed rename falls back to the original URL so
        // transcription still happens.
        let workingURL = await renameIfNeeded(url, with: snapshot) ?? url

        // 0c. Pull the compiled prompt off the snapshot. Empty string and
        // nil collapse to nil — the transcription client omits the field
        // entirely in that case, matching pre-Add-Context behaviour.
        let prompt = snapshot
            .map(\.resolvedCompiledContext)
            .flatMap { $0.isEmpty ? nil : $0 }
        Log.pipeline.info("Prompt attached: \(prompt != nil ? "yes" : "no", privacy: .public)")

        do {
            // 1. Transcribe.
            let transcript = try await transcriptionClient.transcribe(
                audio: workingURL,
                baseURL: config.apiBaseURL,
                model: config.model,
                apiKey: config.apiKey,
                prompt: prompt
            )

            // 2. Organize: per-meeting folder + transcript + (optional)
            // context.md + move audio. Prompt is the same string that just
            // went to the API — kept on disk for reproducibility (PRD §8).
            let meetingFolder = try await fileOrganizer.organize(
                audio: workingURL,
                transcript: transcript,
                context: prompt,
                outputRoot: config.outputFolder
            )

            // 3. Success — clear watcher state for this path so the user can
            // drop a new file at the same path and have it picked up. The
            // ledger entry was the right call while the file was still
            // sitting in the Watch Folder (prevents double-processing on a
            // relaunch), but now the file has been moved out and the entry
            // is moot.
            await watcher.forget(workingURL)

            // 4. Log + reset state. Notion-aware pipelines stamp the
            // initial `notionStatus` on the entry — either `.pending`
            // (we're about to attempt the write) or `.skipped(reason)`.
            // The `.pending` row gets updated in place when the async
            // task in step 5 resolves.
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            let entryId = UUID()
            let initialStatus = initialNotionStatus()
            onAuditEntry(.init(
                id: entryId,
                kind: .success,
                sourcePath: workingURL.path(percentEncoded: false),
                message: "Transcribed and filed → \(meetingFolder.lastPathComponent)",
                durationMs: ms,
                retryable: false,
                contextAttached: prompt != nil,
                organizationName: snapshot?.organizationName,
                notionStatus: initialStatus
            ))
            onStateChange(.idle)

            // 5. Fire the Notion write as a background task on success
            // *only* in `.attempt` mode. The main pipeline returns to
            // idle immediately — Notion never blocks the success path.
            if case .attempt(let notionConfig, let writer) = notionMode {
                // Source the meeting name + additional context from the
                // recording snapshot when we have one; fall back to the
                // audio basename + empty context for files that arrived
                // outside a Jot-kicked session.
                let meetingName = snapshot?.meetingName
                    ?? workingURL.deletingPathExtension().lastPathComponent
                let additionalContext = snapshot?.resolvedCompiledContext ?? ""
                scheduleNotionWrite(
                    entryId: entryId,
                    config: notionConfig,
                    writer: writer,
                    meetingName: meetingName,
                    transcript: transcript,
                    additionalContext: additionalContext
                )
            }

        } catch let error as TranscriptionError {
            recordFailure(url: workingURL, message: error.userFacingMessage, startedAt: startTime, snapshot: snapshot, promptIncluded: prompt != nil)
        } catch let error as FileOrganizerError {
            recordFailure(url: workingURL, message: error.userFacingMessage, startedAt: startTime, snapshot: snapshot, promptIncluded: prompt != nil)
        } catch is CancellationError {
            // Shutdown happened mid-flight — don't log as failure.
            return
        } catch {
            recordFailure(url: workingURL, message: error.localizedDescription, startedAt: startTime, snapshot: snapshot, promptIncluded: prompt != nil)
        }
    }

    /// Ask `consumeMeetingContext` for a snapshot matching `url`'s creation
    /// date. Returns nil if no callback is wired, no creation date is
    /// readable, or no snapshot matches (file came from outside a
    /// Jot-driven session). Side effect: a successful consume clears the
    /// store's pending entry — we can only spend it once.
    private func consumeSnapshotForFile(at url: URL) async -> MeetingContextSnapshot? {
        guard let consume = consumeMeetingContext else { return nil }
        guard let creationDate = fileCreationDate(of: url) else { return nil }
        return await consume(creationDate)
    }

    /// Try to rename `url` to the snapshot's meeting name. Returns the new
    /// URL on success, or nil if no rename happened (no snapshot, sanitized
    /// name empty, or the actual `moveItem` failed). Never throws — rename
    /// is strictly best-effort and must not block transcription.
    ///
    /// The new basename is prefixed with the file's creation timestamp in
    /// `yyyy.MM.dd - HH.mm` form so meeting folders sort chronologically
    /// by name in Finder. The downstream `FileOrganizer` derives the
    /// folder + transcript filenames from the audio's basename, so the
    /// timestamp propagates through automatically.
    private func renameIfNeeded(_ url: URL, with snapshot: MeetingContextSnapshot?) async -> URL? {
        guard let snapshot else { return nil }
        guard let safeName = MeetingContextStore.sanitizedFilenameComponent(snapshot.meetingName) else { return nil }

        let timestamp = Self.folderTimestamp(for: fileCreationDate(of: url) ?? Date())
        let prefixedName = "\(timestamp) - \(safeName)"
        let parent = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let target = uniqueAudioURL(under: parent, baseName: prefixedName, ext: ext)

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

    /// `yyyy.MM.dd - HH.mm` in local time — the prefix that gives meeting
    /// folders chronological sort order in Finder. Uses `en_US_POSIX` to
    /// keep the format locale-independent; uses the current `TimeZone` so
    /// the prefix matches the user's wall-clock view of the meeting.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy.MM.dd - HH.mm"
        return f
    }()

    nonisolated static func folderTimestamp(for date: Date) -> String {
        timestampFormatter.string(from: date)
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

    private func recordFailure(
        url: URL,
        message: String,
        startedAt: Date,
        snapshot: MeetingContextSnapshot? = nil,
        promptIncluded: Bool = false
    ) {
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        onAuditEntry(.init(
            kind: .failure,
            sourcePath: url.path(percentEncoded: false),
            message: message,
            durationMs: ms,
            retryable: true,
            contextAttached: promptIncluded,
            organizationName: snapshot?.organizationName
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

    // MARK: - Notion post-success

    /// Initial `notionStatus` stamped on the success entry — driven by
    /// the pipeline's mode, not by anything per-file. Returns nil when
    /// the pipeline isn't Notion-aware at all (test default), so legacy
    /// rows stay shape-compatible.
    private func initialNotionStatus() -> NotionStatus? {
        switch notionMode {
        case .none:
            return nil
        case .skip(let reason):
            return .skipped(reason: reason)
        case .attempt:
            return .pending
        }
    }

    /// Kick off the Notion write in the background. When it completes
    /// (success, typed error, or transport error), surface the outcome
    /// via `onNotionStatusChange` so the audit row is updated in place.
    /// Cancellation during `stop()` is silent by design.
    private func scheduleNotionWrite(
        entryId: UUID,
        config notionConfig: NotionConfig,
        writer: any NotionMeetingWriter,
        meetingName: String,
        transcript: String,
        additionalContext: String
    ) {
        let task = Task { [weak self] in
            let outcome: NotionStatus
            do {
                let result = try await writer.createMeetingPage(
                    config: notionConfig,
                    meetingName: meetingName,
                    transcript: transcript,
                    additionalContext: additionalContext
                )
                outcome = .succeeded(pageURL: result.url)
                Log.notion.info("Notion page created → \(result.url.absoluteString, privacy: .public)")
            } catch is CancellationError {
                return
            } catch let error as NotionError {
                outcome = .failed(message: error.userFacingMessage)
                Log.notion.error("Notion write failed: \(error.userFacingMessage, privacy: .public)")
            } catch {
                outcome = .failed(message: error.localizedDescription)
                Log.notion.error("Notion write failed: \(error.localizedDescription, privacy: .public)")
            }
            // Hand the outcome back to the host and drop our task handle.
            self?.onNotionStatusChange?(entryId, outcome)
            await self?.clearNotionTask(entryId)
        }
        notionTasks[entryId] = task
    }

    /// Internal helper for `scheduleNotionWrite`'s completion path — runs
    /// on the actor so the dictionary mutation is serialized.
    private func clearNotionTask(_ entryId: UUID) {
        notionTasks[entryId] = nil
    }
}
