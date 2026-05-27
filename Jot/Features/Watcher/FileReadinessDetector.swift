import Foundation

/// Snapshot of a file's volatile state — `size` + `modificationDate` — at a
/// particular moment in time. Used by `FileReadinessDetector` to decide when
/// Audio Hijack has finished writing.
struct FileSnapshot: Equatable, Hashable, Sendable {
    let size: UInt64
    let modificationDate: Date
}

/// Per-file state machine that decides "is this file done being written?"
///
/// **The rule** (PRD §4.1 + plan §3 step 2): a file is "ready" only when
/// `(size, modificationDate)` has been observed unchanged for at least
/// `stableDuration` seconds. Audio Hijack writes incrementally — without
/// this debounce we'd upload an in-progress recording.
///
/// **Why an actor:** the watcher will call `observe(...)` from a background
/// queue; tests want deterministic, sequential access. An actor gives us
/// both for free.
///
/// **Why no `Clock`:** the caller passes the observation time as a parameter.
/// That keeps the detector pure-functional w.r.t. time — tests inject
/// synthetic `Date`s and assert on transitions without any sleeping.
actor FileReadinessDetector {

    /// How long `(size, mtime)` must be unchanged before we call the file ready.
    let stableDuration: TimeInterval

    /// Per-URL bookkeeping: the snapshot we last observed and when we first
    /// observed it. If `observe(...)` sees an identical snapshot later and
    /// `time - stableSince >= stableDuration`, the file is ready.
    private var observations: [URL: (snapshot: FileSnapshot, stableSince: Date)] = [:]

    /// URLs we've already emitted as ready. Subsequent observations for the
    /// same URL are no-ops — the watcher's `ProcessedFilesLedger` then
    /// guarantees the file isn't re-processed.
    private var emitted: Set<URL> = []

    init(stableDuration: TimeInterval = 2.0) {
        precondition(stableDuration >= 0, "stableDuration must be non-negative")
        self.stableDuration = stableDuration
    }

    /// Feed an observation through the state machine.
    /// - Returns: `true` if this observation *just now* marks the file as
    ///   newly ready. Returns `false` in every other case (still growing,
    ///   not yet stable long enough, already emitted, etc.).
    @discardableResult
    func observe(url: URL, snapshot: FileSnapshot, at time: Date) -> Bool {
        if emitted.contains(url) {
            return false
        }

        if let prior = observations[url], prior.snapshot == snapshot {
            // Same as last observation → check stability duration.
            let elapsed = time.timeIntervalSince(prior.stableSince)
            if elapsed >= stableDuration {
                emitted.insert(url)
                return true
            }
            return false
        } else {
            // First sighting or snapshot changed → reset stability timer.
            observations[url] = (snapshot, time)
            return false
        }
    }

    /// Drop all bookkeeping for `url`. Call this when a file is deleted,
    /// moved out of the watch folder, or after the pipeline has fully
    /// processed it.
    func forget(_ url: URL) {
        observations.removeValue(forKey: url)
        emitted.remove(url)
    }

    /// Reset to a clean slate. Used when the watched folder changes.
    func reset() {
        observations.removeAll()
        emitted.removeAll()
    }

    // MARK: - Test inspection

    /// Whether `url` has been emitted as ready in this detector's lifetime.
    func hasEmitted(_ url: URL) -> Bool {
        emitted.contains(url)
    }

    /// The latest known snapshot for `url`, or `nil` if we've never seen it.
    func snapshot(for url: URL) -> FileSnapshot? {
        observations[url]?.snapshot
    }
}
