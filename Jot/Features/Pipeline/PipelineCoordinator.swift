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
        menuBar: MenuBarController
    ) {
        self.settings = settings
        self.auditLog = auditLog
        self.menuBar = menuBar
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
    /// changes. Uses `withObservationTracking` per-iteration — that's how
    /// `@Observable` is consumed outside SwiftUI views.
    private func waitForRelevantChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = settings.watchFolderBookmark
                _ = settings.outputFolderBookmark
                _ = settings.apiBaseURL
                _ = settings.modelString
                // apiKey is computed (Keychain-backed), so it's not
                // observable. We rely on the user clicking through the UI
                // for key changes; restart by user action via the toggle
                // we'll add or by quit + relaunch.
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
                }
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
    private func makeConfig() -> PipelineConfig? {
        guard let watch = settings.watchFolderBookmark,
              let output = settings.outputFolderBookmark,
              let watchURL = resolveBookmark(watch),
              let outputURL = resolveBookmark(output)
        else { return nil }

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
