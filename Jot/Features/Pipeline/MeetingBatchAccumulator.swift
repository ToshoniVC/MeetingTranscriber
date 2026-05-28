import Foundation

/// A meeting whose recording was split across multiple files (Audio Hijack
/// 4's "Split when file reaches X MB" Recorder setting). All parts belong
/// to the same `MeetingContextStore` snapshot — same name, same
/// organization, same compiled context — and should produce one meeting
/// folder, one concatenated transcript, and one Notion page.
struct MeetingBatch: Sendable, Equatable {
    let snapshot: MeetingContextSnapshot
    let startedAt: Date
    let stoppedAt: Date
    /// Parts in chronological order (ascending file creation date).
    let parts: [URL]
}

/// What the pipeline pulls off the watcher → accumulator stream. A single
/// file (no active recording window, or a stale arrival after the settle
/// period) takes the existing one-meeting-per-file path; a batch takes the
/// new multi-part path added in v0.4.1.
enum PipelineWorkItem: Sendable, Equatable {
    case single(URL)
    case batch(MeetingBatch)
}

/// Groups stable file URLs that fall inside a Jot-initiated recording
/// window into one `MeetingBatch`, so an Audio Hijack split-file
/// recording (e.g., 30-minute meeting split into 20 MB chunks to stay
/// under OpenAI's 25 MB Whisper upload limit) processes as one logical
/// meeting rather than N independent transcriptions.
///
/// **Lifecycle:**
///   1. `HotkeyCoordinator` (or whoever owns the start/stop signal) calls
///      `noteRecordingStarted(...)` when the user kicks off a recording.
///   2. The watcher calls `ingest(_:creationDate:)` every time a file
///      stabilizes. If it falls inside the active window, it's buffered;
///      otherwise it's emitted immediately as `.single`.
///   3. On `noteRecordingStopped(...)`, a settle timer (default 5 s) gives
///      the trailing split part time to land in the watch folder. When the
///      timer fires, the buffered parts emit as a `.batch`.
///
/// **Race notes:**
/// - If a file stabilizes *before* `noteRecordingStarted` (slow user
///   typing into the metadata prompt, AH already split mid-prompt): the
///   file emits as `.single`. Acceptable for v0.4.1.
/// - If `noteRecordingStarted` is called while another session is still
///   in settle: the in-flight session flushes immediately and the new
///   one begins clean.
/// - If `stop()` is called with a pending settle timer: the timer is
///   cancelled and any buffered parts emit as `.batch` synchronously.
///
/// **Why an actor:** serialized state (`currentSession`, `settleTask`,
/// `emitter`) without locks, and the emit callback always runs on the
/// actor's executor so callers don't have to think about ordering.
actor MeetingBatchAccumulator {

    /// Tolerance applied to both bounds of the recording window when
    /// deciding membership. Matches `MeetingContextStore.timestampSlop`
    /// for consistency — a file whose creation date is within ±2 s of the
    /// recording window is considered part of it.
    private static let timestampSlop: TimeInterval = 2

    /// Seconds to wait after `noteRecordingStopped` before flushing the
    /// batch. Sized to swallow FSEvents debounce plus Audio Hijack's
    /// closing-file-handle delay on the trailing part. 5 s is the
    /// hotfix default; the constructor lets tests pin it lower.
    private let settleDelay: TimeInterval

    /// Closure the pipeline wires in via `setEmitter` to receive
    /// `PipelineWorkItem`s. Stored as an optional so the accumulator can
    /// be constructed before the pipeline exists (JotApp init ordering)
    /// and the emitter wired afterwards. Calls into the emitter are
    /// `await`-ed inside the actor — the emitter is responsible for its
    /// own concurrency.
    private var emitter: (@Sendable (PipelineWorkItem) async -> Void)?

    /// Buffered URLs the accumulator has seen so far, keyed by path so
    /// repeat FSEvents on the same file don't double-add. Insertion
    /// order is preserved by `keys`, but the emitter sorts by creation
    /// date — `creationDates` keeps that data alongside the URLs.
    private var currentSession: Session?

    /// In-flight settle task armed by `noteRecordingStopped`. Holding the
    /// handle lets us cancel it cleanly on `stop()` or on a back-to-back
    /// `noteRecordingStarted`.
    private var settleTask: Task<Void, Never>?

    private struct Session {
        let snapshot: MeetingContextSnapshot
        let startedAt: Date
        var stoppedAt: Date?
        var parts: [BufferedPart]
    }

    private struct BufferedPart: Equatable {
        let url: URL
        let creationDate: Date
    }

    init(settleDelay: TimeInterval = 5) {
        self.settleDelay = settleDelay
    }

    // MARK: - Wiring

    /// Provide the closure the accumulator calls to push items downstream.
    /// Idempotent — setting twice replaces the previous emitter.
    func setEmitter(_ emitter: @escaping @Sendable (PipelineWorkItem) async -> Void) {
        self.emitter = emitter
    }

    /// Detach the current emitter without clearing recording-session
    /// state. Called by `ProcessingPipeline.stop()` so events fired
    /// against a stale pipeline get silently dropped while still letting
    /// a new pipeline rebind via `setEmitter` later.
    func unsetEmitter() {
        self.emitter = nil
    }

    // MARK: - Recording lifecycle

    /// Note that recording has started. Any in-flight session (e.g., a
    /// previous recording whose settle timer is still ticking) flushes
    /// immediately so its parts don't leak into the new meeting.
    func noteRecordingStarted(snapshot: MeetingContextSnapshot, at startedAt: Date) async {
        await flushNow()
        currentSession = Session(
            snapshot: snapshot,
            startedAt: startedAt,
            stoppedAt: nil,
            parts: []
        )
    }

    /// Note that recording has stopped. Arms a settle timer; when it
    /// expires, the batch (or remaining single if only one part landed)
    /// emits. No-op if no session is currently in flight.
    func noteRecordingStopped(at stoppedAt: Date) {
        guard var session = currentSession else { return }
        session.stoppedAt = stoppedAt
        currentSession = session

        settleTask?.cancel()
        settleTask = Task { [weak self, settleDelay] in
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flushNow()
        }
    }

    // MARK: - File ingestion

    /// Ingest a stable URL from the watcher. If a recording window is
    /// currently open (or recently closed and within its settle period)
    /// and `creationDate` matches, the URL is buffered. Otherwise it's
    /// emitted as a `.single` straight away.
    func ingest(_ url: URL, creationDate: Date, now: Date = Date()) async {
        if var session = currentSession, matches(session: session, creationDate: creationDate, now: now) {
            if !session.parts.contains(where: { $0.url == url }) {
                session.parts.append(BufferedPart(url: url, creationDate: creationDate))
                currentSession = session
            }
            return
        }
        await emit(.single(url))
    }

    // MARK: - Shutdown

    /// Cancel any pending settle timer, flush whatever's buffered, and
    /// drop the emitter. Pipeline calls this on stop so the accumulator
    /// doesn't outlive the watcher / pipeline pair.
    func stop() async {
        settleTask?.cancel()
        settleTask = nil
        await flushNow()
        emitter = nil
    }

    // MARK: - Internals

    private func matches(session: Session, creationDate: Date, now: Date) -> Bool {
        let lower = session.startedAt.addingTimeInterval(-Self.timestampSlop)
        let upper = (session.stoppedAt ?? now).addingTimeInterval(Self.timestampSlop)
        return creationDate >= lower && creationDate <= upper
    }

    /// Drain the current session. Parts are sorted by creation date asc;
    /// zero parts emit nothing, one part emits as `.single` (no need for
    /// a batch wrapper when there was no split), two-or-more parts emit
    /// as `.batch`. The session is cleared in all cases.
    private func flushNow() async {
        guard let session = currentSession else { return }
        currentSession = nil
        settleTask?.cancel()
        settleTask = nil

        let sorted = session.parts.sorted { $0.creationDate < $1.creationDate }
        switch sorted.count {
        case 0:
            return
        case 1:
            await emit(.single(sorted[0].url))
        default:
            let batch = MeetingBatch(
                snapshot: session.snapshot,
                startedAt: session.startedAt,
                stoppedAt: session.stoppedAt ?? session.startedAt,
                parts: sorted.map(\.url)
            )
            await emit(.batch(batch))
        }
    }

    private func emit(_ item: PipelineWorkItem) async {
        guard let emitter else { return }
        await emitter(item)
    }
}
