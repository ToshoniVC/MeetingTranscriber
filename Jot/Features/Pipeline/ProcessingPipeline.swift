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

/// How the pipeline should treat the post-Notion Claude Code routine
/// trigger. Snapshotted at pipeline-start time alongside
/// `NotionPipelineMode` so settings churn doesn't affect in-flight
/// meetings — the coordinator restarts on any change.
enum ClaudeCodePipelineMode: Sendable {
    /// User opted out (toggle off) or config didn't pass validation.
    /// The success audit entry is stamped with
    /// `claudeCodeStatus = .skipped(reason)` and no network call
    /// happens. PRD §4.3 + §6.
    case skip(reason: ClaudeCodeRoutineStatus.SkipReason)

    /// Wire the routine firing client. After Notion succeeds, the
    /// pipeline fires the routine and updates `claudeCodeStatus` in
    /// place via `onClaudeCodeStatusChange`.
    case attempt(config: ClaudeCodeRoutineConfig, firing: any ClaudeCodeRoutineFiring)
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
    ///
    /// Only used by the **single-file** path. The batched path
    /// (`processBatch`) gets its snapshot off the `MeetingBatch` itself,
    /// which the `MeetingBatchAccumulator` populated when recording
    /// started.
    private let consumeMeetingContext: (@Sendable (Date) async -> MeetingContextSnapshot?)?

    /// Optional batch accumulator. When set, every stable URL from the
    /// watcher is routed through it first — files that fall inside an
    /// active recording window get buffered into a `MeetingBatch` and
    /// emit only after the recording stops + a settle period. Files
    /// outside any window emit as `.single` and take the existing
    /// per-file path. Nil for non-batching test contexts.
    private let batchAccumulator: MeetingBatchAccumulator?

    /// Called by the batch path after it finishes (success or failure) so
    /// the `MeetingContextStore`'s `pending` entry is cleared — the batch
    /// already grabbed the snapshot at `noteRecordingStarted` time, and
    /// leaving `pending` set would mis-attribute a late-arriving stray
    /// file to the just-flushed meeting via the legacy `consume` path.
    /// Nil for non-batching contexts.
    private let clearPendingMeetingContext: (@Sendable () async -> Void)?

    /// How to handle Notion post-success — either skip with a recorded
    /// reason or attempt the write via the supplied writer. Nil means
    /// the pipeline isn't Notion-aware at all (test harnesses default);
    /// in that case `notionStatus` on entries stays nil.
    private let notionMode: NotionPipelineMode?

    /// Called when an in-flight Notion task resolves — `(entryId, finalStatus)`.
    /// Hosts (the coordinator) update the corresponding audit entry's
    /// `notionStatus` in the store. Ignored when `notionMode == nil`.
    private let onNotionStatusChange: (@Sendable (UUID, NotionStatus) -> Void)?

    /// How to handle the post-Notion Claude Code routine trigger. Nil
    /// means the pipeline isn't Claude-Code-aware at all (test harnesses
    /// default); in that case `claudeCodeStatus` on entries stays nil.
    private let claudeCodeMode: ClaudeCodePipelineMode?

    /// Called when an in-flight Claude Code fire resolves —
    /// `(entryId, finalStatus)`. Hosts update the corresponding audit
    /// entry's `claudeCodeStatus` in the store. Ignored when
    /// `claudeCodeMode == nil`.
    private let onClaudeCodeStatusChange: (@Sendable (UUID, ClaudeCodeRoutineStatus) -> Void)?

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
        batchAccumulator: MeetingBatchAccumulator? = nil,
        clearPendingMeetingContext: (@Sendable () async -> Void)? = nil,
        notionMode: NotionPipelineMode? = nil,
        onNotionStatusChange: (@Sendable (UUID, NotionStatus) -> Void)? = nil,
        claudeCodeMode: ClaudeCodePipelineMode? = nil,
        onClaudeCodeStatusChange: (@Sendable (UUID, ClaudeCodeRoutineStatus) -> Void)? = nil
    ) {
        self.config = config
        self.watcher = watcher
        self.transcriptionClient = transcriptionClient
        self.fileOrganizer = fileOrganizer
        self.onStateChange = onStateChange
        self.onAuditEntry = onAuditEntry
        self.consumeMeetingContext = consumeMeetingContext
        self.batchAccumulator = batchAccumulator
        self.clearPendingMeetingContext = clearPendingMeetingContext
        self.notionMode = notionMode
        self.onNotionStatusChange = onNotionStatusChange
        self.claudeCodeMode = claudeCodeMode
        self.onClaudeCodeStatusChange = onClaudeCodeStatusChange
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

        // Wire the accumulator's emitter back to ourselves so a `.batch`
        // becomes `processBatch(_:)` and a `.single` becomes the existing
        // `process(url:)` path. Done here (not in init) so the closure
        // sees a fully-initialized pipeline.
        if let batchAccumulator {
            await batchAccumulator.setEmitter { [weak self] item in
                await self?.handleWorkItem(item)
            }
        }

        consumerTask = Task { [weak self] in
            for await url in stream {
                await self?.routeFromWatcher(url)
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
        // Detach the accumulator's emitter — recording-session state
        // survives a settings-change-induced pipeline restart, but events
        // fired between stop and the next start would land on a torn-down
        // pipeline. The next `start()` rebinds.
        await batchAccumulator?.unsetEmitter()
        await watcher.stop()
        onStateChange(.notConfigured)
    }

    /// Route a stable URL from the watcher. When a batch accumulator is
    /// wired, every URL flows through it; otherwise we fall through to
    /// the legacy single-file path (preserves existing test wiring).
    private func routeFromWatcher(_ url: URL) async {
        guard let batchAccumulator else {
            await process(url: url)
            return
        }
        let creationDate = fileCreationDate(of: url) ?? Date()
        await batchAccumulator.ingest(url, creationDate: creationDate)
    }

    /// Dispatch a work item produced by the accumulator's emitter.
    private func handleWorkItem(_ item: PipelineWorkItem) async {
        switch item {
        case .single(let url):
            await process(url: url)
        case .batch(let batch):
            await processBatch(batch)
        }
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
            let result = try await transcriptionClient.transcribe(
                audio: workingURL,
                baseURL: config.apiBaseURL,
                model: config.model,
                apiKey: config.apiKey,
                prompt: prompt
            )

            // 2. Organize: per-meeting folder + `.txt` + `.json` +
            // (optional) context.md + move audio. Prompt is the same
            // string that just went to the API — kept on disk for
            // reproducibility (PRD §8). Since v0.4.4 we write both the
            // plain text (fast read in Quick Look) AND the verbose JSON
            // (timestamps + segments).
            let meetingFolder = try await fileOrganizer.organize(
                audio: workingURL,
                transcriptText: result.text,
                transcriptJSON: result.rawJSON,
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
            // task in step 5 resolves. Same shape for Claude Code:
            // either `.skipped(...)` or nil (pending — will be filled
            // in by the post-Notion routine fire).
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            let entryId = UUID()
            let initialStatus = initialNotionStatus()
            let initialClaudeCodeStatus = initialClaudeCodeStatus()
            onAuditEntry(.init(
                id: entryId,
                kind: .success,
                sourcePath: workingURL.path(percentEncoded: false),
                message: "Transcribed and filed → \(meetingFolder.lastPathComponent)",
                durationMs: ms,
                retryable: false,
                contextAttached: prompt != nil,
                organizationName: snapshot?.organizationName,
                notionStatus: initialStatus,
                claudeCodeStatus: initialClaudeCodeStatus
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
                // Send Notion the timestamped rendering so the meeting
                // page reads like minutes with jump-back anchors, not
                // one wall of text. Falls back to the plain text when
                // the endpoint returned no segments.
                let notionBody = TimestampedTranscriptFormatter.formatBody(for: result)
                scheduleNotionWrite(
                    entryId: entryId,
                    config: notionConfig,
                    writer: writer,
                    meetingName: meetingName,
                    transcript: notionBody,
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

    // MARK: - Per-meeting (multi-part) processing

    /// Process a `MeetingBatch` — a single meeting whose recording Audio
    /// Hijack split into multiple files. All parts share the snapshot
    /// the accumulator captured at `noteRecordingStarted` time; they're
    /// transcribed in chronological order, the transcripts are joined
    /// with a blank line, and the result lands as a single meeting
    /// folder + audit row + Notion page.
    ///
    /// On failure of any part's transcription or the organize step, the
    /// whole batch is recorded as one failure row referencing the first
    /// part — the other parts stay in the Watch Folder for retry.
    private func processBatch(_ batch: MeetingBatch) async {
        let startTime = Date()
        let snapshot = batch.snapshot
        guard let firstPart = batch.parts.first else {
            // Accumulator should never emit an empty batch, but guard
            // defensively rather than crashing the actor.
            return
        }

        onStateChange(.processing(firstPart))

        // 1. Rename each part with the meeting name and a "(part N)"
        // suffix for N > 1. Part 1 keeps the bare meeting-named filename
        // so the meeting folder + transcript pick it up via
        // `FileOrganizer`'s `baseName` lookup. Best-effort: a failed
        // rename falls back to the original URL.
        let renamedParts = await renameParts(batch.parts, snapshot: snapshot)

        let prompt = snapshot.resolvedCompiledContext.isEmpty
            ? nil
            : snapshot.resolvedCompiledContext
        Log.pipeline.info("Batch processing \(renamedParts.count, privacy: .public) parts; prompt attached: \(prompt != nil ? "yes" : "no", privacy: .public)")

        do {
            // 2. Transcribe each part in order. Same prompt for every
            // part — the compiled context is the user's whole-meeting
            // intent and applies to all parts.
            var partResults: [TranscriptionResult] = []
            partResults.reserveCapacity(renamedParts.count)
            for part in renamedParts {
                let result = try await transcriptionClient.transcribe(
                    audio: part,
                    baseURL: config.apiBaseURL,
                    model: config.model,
                    apiKey: config.apiKey,
                    prompt: prompt
                )
                partResults.append(result)
            }

            // 3. Merge per-part results into one logical transcription.
            // Segment timestamps are shifted by cumulative part duration
            // so the on-disk JSON + Notion rendering read as one
            // continuous recording rather than each part restarting at
            // zero.
            let mergedResult = TranscriptionResult.merging(partResults)

            // 4. Organize: one meeting folder containing all parts + the
            // merged transcript (.txt + .json) + context.md.
            let meetingFolder = try await fileOrganizer.organize(
                audioParts: renamedParts,
                transcriptText: mergedResult.text,
                transcriptJSON: mergedResult.rawJSON,
                context: prompt,
                outputRoot: config.outputFolder
            )

            // 5. Watcher ledger cleanup for every part.
            for part in renamedParts {
                await watcher.forget(part)
            }

            // 6. One success audit entry covering the whole batch.
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            let entryId = UUID()
            let initialStatus = initialNotionStatus()
            let initialClaudeCodeStatus = initialClaudeCodeStatus()
            let partCount = renamedParts.count
            onAuditEntry(.init(
                id: entryId,
                kind: .success,
                sourcePath: firstPart.path(percentEncoded: false),
                message: "Transcribed and filed (\(partCount) parts) → \(meetingFolder.lastPathComponent)",
                durationMs: ms,
                retryable: false,
                contextAttached: prompt != nil,
                organizationName: snapshot.organizationName,
                notionStatus: initialStatus,
                claudeCodeStatus: initialClaudeCodeStatus
            ))
            onStateChange(.idle)

            // 7. One Notion write for the whole meeting. Same
            // timestamped rendering as the single-file path.
            if case .attempt(let notionConfig, let writer) = notionMode {
                let notionBody = TimestampedTranscriptFormatter.formatBody(for: mergedResult)
                scheduleNotionWrite(
                    entryId: entryId,
                    config: notionConfig,
                    writer: writer,
                    meetingName: snapshot.meetingName,
                    transcript: notionBody,
                    additionalContext: snapshot.resolvedCompiledContext
                )
            }

        } catch let error as TranscriptionError {
            recordFailure(url: firstPart, message: error.userFacingMessage, startedAt: startTime, snapshot: snapshot, promptIncluded: prompt != nil)
        } catch let error as FileOrganizerError {
            recordFailure(url: firstPart, message: error.userFacingMessage, startedAt: startTime, snapshot: snapshot, promptIncluded: prompt != nil)
        } catch is CancellationError {
            return
        } catch {
            recordFailure(url: firstPart, message: error.localizedDescription, startedAt: startTime, snapshot: snapshot, promptIncluded: prompt != nil)
        }

        // The accumulator's snapshot has done its job. Tell the store to
        // drop its `pending` entry so a late stray file (one that lands
        // after the settle period) can't accidentally inherit this
        // meeting's name + context via the legacy `consume` path.
        await clearPendingMeetingContext?()
    }

    /// Rename each split part using the meeting name + timestamp from the
    /// first part's creation date. Part 1 gets the bare
    /// `<timestamp> - <name>.<ext>` form; parts 2..N get
    /// `<timestamp> - <name> (part N).<ext>`. Returns the post-rename
    /// URLs in the same order; any part whose rename failed falls back
    /// to its original URL.
    private func renameParts(_ parts: [URL], snapshot: MeetingContextSnapshot) async -> [URL] {
        guard !parts.isEmpty else { return parts }
        guard let safeName = MeetingContextStore.sanitizedFilenameComponent(snapshot.meetingName) else {
            // Can't form a meeting name — keep original filenames so the
            // organize step still picks up all parts (the folder name
            // will fall back to the first part's existing basename).
            return parts
        }
        let timestamp = Self.folderTimestamp(for: fileCreationDate(of: parts[0]) ?? Date())
        let parent = parts[0].deletingLastPathComponent()

        var out: [URL] = []
        out.reserveCapacity(parts.count)
        for (index, part) in parts.enumerated() {
            let partLabel = index == 0 ? "" : " (part \(index + 1))"
            let baseName = "\(timestamp) - \(safeName)\(partLabel)"
            let ext = part.pathExtension
            let target = uniqueAudioURL(under: parent, baseName: baseName, ext: ext)

            await watcher.preRecord(target)
            do {
                try FileManager.default.moveItem(at: part, to: target)
                await watcher.forget(part)
                onAuditEntry(.init(
                    kind: .info,
                    sourcePath: target.path(percentEncoded: false),
                    message: "Renamed \(part.lastPathComponent) → \(target.lastPathComponent) (meeting name)"
                ))
                Log.pipeline.info("Renamed \(part.lastPathComponent, privacy: .public) → \(target.lastPathComponent, privacy: .public)")
                out.append(target)
            } catch {
                await watcher.forget(target)
                Log.pipeline.warning("Batch rename failed for \(part.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                out.append(part)
            }
        }
        return out
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

    /// Initial `claudeCodeStatus` for the success entry. Skip cases are
    /// known up-front; the attempt path leaves the field nil at the
    /// success-entry write moment and the post-Notion task fills in
    /// `.fired` / `.failed` later. Returns nil entirely when the
    /// pipeline isn't Claude-Code-aware.
    private func initialClaudeCodeStatus() -> ClaudeCodeRoutineStatus? {
        switch claudeCodeMode {
        case .none:
            return nil
        case .skip(let reason):
            return .skipped(reason: reason)
        case .attempt:
            // The post-Notion task will surface the real outcome via
            // `onClaudeCodeStatusChange`. We leave the field nil here
            // rather than introducing a `.pending` state — the audit
            // row reads "Notes: …" only once the routine fires.
            return nil
        }
    }

    /// Kick off the Notion write in the background. When it completes
    /// (success, typed error, or transport error), surface the outcome
    /// via `onNotionStatusChange` so the audit row is updated in place.
    /// Cancellation during `stop()` is silent by design.
    ///
    /// On Notion success, if `claudeCodeMode == .attempt(...)`, also
    /// fires the Claude Code routine and surfaces its outcome via
    /// `onClaudeCodeStatusChange`. PRD §4.3 requires this strict order:
    /// transcript → Notion → routine fire. Notion failure short-circuits
    /// the routine with a `.skipped(reason: .notionNotReady)` so the
    /// audit row honestly reflects why no notes were generated.
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
            var pageURL: URL?
            do {
                let result = try await writer.createMeetingPage(
                    config: notionConfig,
                    meetingName: meetingName,
                    transcript: transcript,
                    additionalContext: additionalContext
                )
                outcome = .succeeded(pageURL: result.url)
                pageURL = result.url
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

            // Post-Notion: fire the Claude Code routine when configured,
            // but only when the Notion write actually succeeded — the
            // routine has nothing to write into otherwise.
            await self?.fireClaudeCodeRoutineIfReady(
                entryId: entryId,
                notionPageURL: pageURL,
                meetingName: meetingName
            )

            await self?.clearNotionTask(entryId)
        }
        notionTasks[entryId] = task
    }

    /// Fire the configured Claude Code routine after a Notion write,
    /// honoring the strict order from PRD §4.3:
    ///   1. transcript success
    ///   2. notion page success (signaled by `notionPageURL != nil`)
    ///   3. routine fire
    ///
    /// Failure of the fire call must not regress earlier outcomes —
    /// the Notion success status has already been reported by the
    /// caller. We surface the routine outcome via
    /// `onClaudeCodeStatusChange` so the audit row's Notes annotation
    /// can be updated in place.
    private func fireClaudeCodeRoutineIfReady(
        entryId: UUID,
        notionPageURL: URL?,
        meetingName: String
    ) async {
        guard case .attempt(let routineConfig, let firing) = claudeCodeMode else {
            // .none / .skip — the success entry already carries the
            // right initial status; no extra work here.
            return
        }
        guard let notionPageURL else {
            // Notion failed (no page URL). Tell the audit row the
            // routine was skipped, with the specific reason, so the
            // user sees why the notes never appeared.
            onClaudeCodeStatusChange?(entryId, .skipped(reason: .notionNotReady))
            Log.claudeCode.info("Routine fire skipped — Notion did not produce a page.")
            return
        }

        // Body composition: user-configured extra text plus a footer
        // line referencing the freshly-created Notion page so the
        // routine knows which page to write into (PRD §5).
        let text = composeRoutineText(
            extraText: routineConfig.extraText,
            notionPageURL: notionPageURL,
            meetingName: meetingName
        )

        do {
            try await firing.fire(config: routineConfig, text: text)
            onClaudeCodeStatusChange?(entryId, .fired)
            Log.claudeCode.info("Claude Code routine fired for meeting → \(notionPageURL.absoluteString, privacy: .public)")
        } catch is CancellationError {
            return
        } catch let error as ClaudeCodeRoutineError {
            onClaudeCodeStatusChange?(entryId, .failed(message: error.userFacingMessage))
            Log.claudeCode.error("Claude Code fire failed: \(error.userFacingMessage, privacy: .public)")
        } catch {
            onClaudeCodeStatusChange?(entryId, .failed(message: error.localizedDescription))
            Log.claudeCode.error("Claude Code fire failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Compose the request body's `text` field. The user's extra text is
    /// preserved verbatim (they may have intentional formatting); a
    /// footer line tells the routine which Notion page to act on. The
    /// PRD (§5) explicitly allows including the page identifier in
    /// `text` as the handoff mechanism.
    private func composeRoutineText(
        extraText: String,
        notionPageURL: URL,
        meetingName: String
    ) -> String {
        let trimmedExtra = extraText.trimmingCharacters(in: .whitespacesAndNewlines)
        let footer = """
        Notion meeting page: \(notionPageURL.absoluteString)
        Meeting name: \(meetingName)
        """
        if trimmedExtra.isEmpty {
            return footer
        }
        return "\(extraText)\n\n\(footer)"
    }

    /// Internal helper for `scheduleNotionWrite`'s completion path — runs
    /// on the actor so the dictionary mutation is serialized.
    private func clearNotionTask(_ entryId: UUID) {
        notionTasks[entryId] = nil
    }
}
