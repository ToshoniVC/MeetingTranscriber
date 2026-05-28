import Foundation
import Observation

/// SwiftUI-side owner of the running `ProcessingPipeline`. Bridges the
/// `@MainActor` world (settings, menu bar, audit log) with the pipeline
/// actor.
///
/// Responsibilities:
///   1. Watch `AppSettings` for pipeline-relevant changes; restart when any
///      change.
///   2. Resolve the security-scoped bookmarks for Watch + Output folders and
///      hold the scoped access for the pipeline's lifetime.
///   3. Translate `PipelineState` updates into `MenuBarController` icon
///      state (via `iconState`), and append `AuditLogEntry` to the store.
///   4. Expose a `retry(_:)` hook for the Audit Log's Retry button.
///
/// Owned by `JotApp` via `@State` so it lives for the app's whole lifetime.
@MainActor
@Observable
final class PipelineCoordinator {

    private let settings: AppSettings
    private let auditLog: AuditLogStore
    private let menuBar: MenuBarController
    private let meetingContextStore: MeetingContextStore?

    /// Long-lived (app-lifetime) accumulator that groups Audio-Hijack-
    /// split files into one `MeetingBatch`. Owned by `JotApp` and
    /// passed in here so its session state survives a settings-change-
    /// induced pipeline restart. Nil for test contexts that don't care
    /// about batching.
    private let batchAccumulator: MeetingBatchAccumulator?

    /// v0.4.5: list of configured transcription providers. The pipeline
    /// uses this via `RotatingTranscriber` instead of the legacy
    /// single-provider fields on `AppSettings`. Nil for test contexts
    /// that drive the pipeline with a `PipelineConfig`-shaped single
    /// provider directly.
    private let providerStore: ProviderStore?

    /// Current pipeline (if running). Nil between starts.
    private var pipeline: ProcessingPipeline?

    /// Scoped resource handles we acquired for the running pipeline.
    /// Released on stop / restart so we don't leak macOS scoped access counts.
    private var scopedURLs: [URL] = []

    /// Snapshot of the config the *current* pipeline was started with.
    /// Used to decide whether a settings change actually needs a restart.
    private var lastStartedConfig: PipelineConfig?

    /// Observation loop task — watches relevant `AppSettings` properties.
    private var observationTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        auditLog: AuditLogStore,
        menuBar: MenuBarController,
        meetingContextStore: MeetingContextStore? = nil,
        batchAccumulator: MeetingBatchAccumulator? = nil,
        providerStore: ProviderStore? = nil
    ) {
        self.settings = settings
        self.auditLog = auditLog
        self.menuBar = menuBar
        self.meetingContextStore = meetingContextStore
        self.batchAccumulator = batchAccumulator
        self.providerStore = providerStore
    }

    // MARK: - Public API

    /// Bootstrap: try to start the pipeline if settings are complete, and
    /// begin observing settings for restart-worthy changes. Call once at
    /// app launch.
    func bootstrap() async {
        await restartIfReady()
        observationTask = Task { [weak self] in
            await self?.observeSettings()
        }
    }

    /// User clicked Retry on a failed Audit Log row.
    func retry(url: URL) async {
        await pipeline?.retry(url: url)
        // If the retry succeeds, the pipeline writes a fresh success entry;
        // we don't pre-emptively dismiss the original failure row.
    }

    /// Reset the menu-bar icon from `.error(...)` back to a healthy state.
    /// Called from the Audit Log's Clear Log button and from a dedicated
    /// "Dismiss error" menu item — both ways the user can explicitly say
    /// "I've seen the error, move on" without having to drop another file.
    ///
    /// Only acts when currently in error state; otherwise a no-op so it's
    /// safe to call defensively.
    func dismissError() {
        guard case .error = menuBar.iconState else { return }
        menuBar.iconState = (pipeline != nil) ? .idle : .notConfigured
    }

    // MARK: - Settings observation

    private func observeSettings() async {
        while !Task.isCancelled {
            await waitForRelevantChange()
            await restartIfReady()
        }
    }

    /// Suspends until any of the pipeline-relevant `AppSettings` properties
    /// (or the `ProviderStore`'s providers list) changes. Uses
    /// `withObservationTracking` per-iteration — that's how `@Observable`
    /// is consumed outside SwiftUI views.
    private func waitForRelevantChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = settings.watchFolderBookmark
                _ = settings.outputFolderBookmark
                // Legacy single-provider fields still observed for
                // tests / contexts that don't wire a `ProviderStore`.
                _ = settings.apiBaseURL
                _ = settings.modelString
                // v0.4.5: provider list / order / enable changes
                // restart the pipeline so the new chain is what the
                // next file sees.
                _ = providerStore?.providers
                _ = settings.notionEnabled
                _ = settings.notionDatabaseId
                _ = settings.claudeCodeNotesEnabled
                _ = settings.claudeCodeEndpoint
                _ = settings.claudeCodeExtraText
                // apiKey, notionToken, and claudeCodeToken are
                // Keychain-backed (not observable). Token changes
                // require the user to flip the corresponding toggle
                // off+on, or quit/relaunch — same shape as the
                // existing apiKey story.
            } onChange: {
                continuation.resume()
            }
        }
    }

    // MARK: - Start / stop

    /// Stop any running pipeline and start a new one if the current settings
    /// produce a valid `PipelineConfig`. Otherwise leave the state at
    /// `.notConfigured`.
    private func restartIfReady() async {
        await stop()
        guard let config = makeConfig() else {
            menuBar.iconState = .notConfigured
            return
        }
        // Idempotent guard: if config is identical to what we just stopped,
        // skip the churn. Not strictly necessary but cheap.
        if config == lastStartedConfig {
            // We just stopped this same config; user might've toggled a
            // setting back and forth. Restart anyway to be safe.
        }
        await start(with: config)
    }

    private func start(with config: PipelineConfig) async {
        // Acquire scoped access. Without these, `FolderWatcher` and
        // `FileOrganizer` see permission-denied under the sandbox (Phase 8)
        // and intermittently outside it.
        _ = config.watchFolder.startAccessingSecurityScopedResource()
        _ = config.outputFolder.startAccessingSecurityScopedResource()
        scopedURLs = [config.watchFolder, config.outputFolder]

        do {
            let watcher = try await FolderWatcher(folderURL: config.watchFolder)
            let consumeMeetingContext: (@Sendable (Date) async -> MeetingContextSnapshot?)?
            let clearPendingMeetingContext: (@Sendable () async -> Void)?
            if let store = meetingContextStore {
                consumeMeetingContext = { creationDate in
                    await MainActor.run {
                        store.consume(forFileCreatedAt: creationDate)
                    }
                }
                clearPendingMeetingContext = {
                    await MainActor.run {
                        store.clearPending()
                    }
                }
            } else {
                consumeMeetingContext = nil
                clearPendingMeetingContext = nil
            }
            let notionMode = makeNotionMode()
            let claudeCodeMode = makeClaudeCodeMode()
            let auditLog = self.auditLog
            let pipeline = ProcessingPipeline(
                config: config,
                watcher: watcher,
                onStateChange: { [weak self] state in
                    Task { @MainActor in
                        self?.menuBar.iconState = state
                    }
                },
                onAuditEntry: { [weak self] entry in
                    Task { @MainActor in
                        self?.auditLog.append(entry)
                    }
                },
                consumeMeetingContext: consumeMeetingContext,
                batchAccumulator: batchAccumulator,
                clearPendingMeetingContext: clearPendingMeetingContext,
                notionMode: notionMode,
                onNotionStatusChange: { entryId, status in
                    Task { @MainActor in
                        auditLog.updateNotionStatus(status, forEntry: entryId)
                    }
                },
                claudeCodeMode: claudeCodeMode,
                onClaudeCodeStatusChange: { entryId, status in
                    Task { @MainActor in
                        auditLog.updateClaudeCodeStatus(status, forEntry: entryId)
                    }
                },
                providerSource: providerStore
            )
            try await pipeline.start()
            self.pipeline = pipeline
            self.lastStartedConfig = config
        } catch {
            menuBar.iconState = .error(config.watchFolder, "Pipeline failed to start: \(error.localizedDescription)")
            auditLog.append(.init(
                kind: .failure,
                sourcePath: config.watchFolder.path(percentEncoded: false),
                message: "Pipeline failed to start: \(error.localizedDescription)",
                retryable: false
            ))
            releaseScopedAccess()
        }
    }

    private func stop() async {
        if let pipeline {
            await pipeline.stop()
            self.pipeline = nil
        }
        releaseScopedAccess()
        lastStartedConfig = nil
    }

    private func releaseScopedAccess() {
        for url in scopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURLs.removeAll()
    }

    // MARK: - Config assembly

    /// Resolve bookmarks + read API config. Returns `nil` if anything
    /// required is missing or resolution fails.
    ///
    /// **Gate logic (v0.4.5).** When a `providerStore` is wired the
    /// pipeline starts as long as at least one enabled provider has
    /// both valid config AND an API key in the keychain — the rotating
    /// transcriber will pick from the chain at request time. The
    /// legacy `apiBaseURL` / `modelString` / `apiKey` fields on
    /// `PipelineConfig` are populated with safe placeholders in that
    /// case (the pipeline ignores them when a provider source is set);
    /// they're still the real gate for test contexts that don't wire
    /// a store.
    private func makeConfig() -> PipelineConfig? {
        guard let watch = settings.watchFolderBookmark,
              let output = settings.outputFolderBookmark,
              let watchURL = resolveBookmark(watch),
              let outputURL = resolveBookmark(output)
        else { return nil }

        if let store = providerStore {
            // Multi-provider gate: any one ready provider unlocks the
            // pipeline. The rotating transcriber surfaces a typed
            // error per-meeting if every provider fails at request
            // time — we don't pre-fail here.
            let readyExists = store.providers.contains { store.readiness(of: $0) == .ready }
            guard readyExists else { return nil }
            return PipelineConfig(
                watchFolder: watchURL,
                outputFolder: outputURL,
                // Placeholder — ignored by ProcessingPipeline when
                // `providerSource` is set. Kept non-empty so the
                // struct's validators don't trip.
                apiBaseURL: URL(string: "https://providers-managed.invalid/")!,
                model: "providers-managed",
                apiKey: "providers-managed"
            )
        }

        // Legacy single-provider gate (tests / contexts without a store).
        let trimmedURL = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmedURL), baseURL.scheme != nil else { return nil }

        let model = settings.modelString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }

        guard let apiKey = settings.apiKey, !apiKey.isEmpty else { return nil }

        return PipelineConfig(
            watchFolder: watchURL,
            outputFolder: outputURL,
            apiBaseURL: baseURL,
            model: model,
            apiKey: apiKey
        )
    }

    /// Decide whether the current `AppSettings` lets the pipeline attempt
    /// a Notion write per meeting. Falls through `NotionValidation`:
    /// `.ready` → `.attempt` with a fresh `NotionClient`; `.disabled` and
    /// `.misconfigured` → `.skip(reason)` so the audit log records why
    /// the write didn't happen.
    private func makeNotionMode() -> NotionPipelineMode {
        switch NotionValidation.validate(settings) {
        case .disabled:
            return .skip(reason: .disabled)
        case .misconfigured:
            return .skip(reason: .misconfigured)
        case .ready(let config):
            return .attempt(config: config, writer: NotionClient())
        }
    }

    /// Decide whether to fire the post-Notion Claude Code routine per
    /// meeting. Mirrors `makeNotionMode()`: `.ready` →
    /// `.attempt(config:firing:)` with a fresh `ClaudeCodeRoutineClient`;
    /// `.disabled` / `.misconfigured` → `.skip(reason)` so the audit row
    /// records why no notes were generated.
    private func makeClaudeCodeMode() -> ClaudeCodePipelineMode {
        switch ClaudeCodeValidation.validate(settings) {
        case .disabled:
            return .skip(reason: .disabled)
        case .misconfigured:
            return .skip(reason: .misconfigured)
        case .ready(let config):
            return .attempt(config: config, firing: ClaudeCodeRoutineClient())
        }
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            Log.pipeline.warning("Bookmark stale for \(url.path(percentEncoded: false), privacy: .public) — folder may have moved")
        }
        return url
    }
}
