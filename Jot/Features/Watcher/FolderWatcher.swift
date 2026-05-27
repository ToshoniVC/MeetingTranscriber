import Foundation

/// Watches a single folder for new audio files and emits them via an
/// `AsyncStream<URL>` once they're done being written.
///
/// **Pipeline:**
/// 1. `DispatchSourceFileSystemObject` on the folder's fd notifies us on any
///    `.write` / `.extend` event (PRD §4.1: "zero polling overhead").
/// 2. On notification, enumerate the folder, snapshot each candidate file
///    (mp3/m4a/wav, not hidden, not a `.tmp`/`.partial`), feed each snapshot
///    through `FileReadinessDetector`.
/// 3. A file that hasn't changed size+mtime for `stableDuration` seconds is
///    "ready" — we check it against `ProcessedFilesLedger`, and if it's new,
///    record it and yield it on the stream.
/// 4. Files still in flight schedule a short re-check (so we notice stability
///    even without further filesystem events).
///
/// **Lifecycle:** call `start()` to begin (returns an `AsyncStream`), `stop()`
/// to tear down. Restarting with a different `folderURL` requires constructing
/// a new instance — keeps the state machine clean.
actor FolderWatcher {

    /// Errors the watcher can throw at construction or start time.
    enum WatcherError: Error, Equatable {
        case folderDoesNotExist(URL)
        case folderNotADirectory(URL)
        case cannotOpenForMonitoring(URL, errno: Int32)
        case alreadyStarted
    }

    let folderURL: URL
    private let detector: FileReadinessDetector
    private let ledger: ProcessedFilesLedger
    private let recheckInterval: TimeInterval

    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var continuation: AsyncStream<URL>.Continuation?
    private var recheckTask: Task<Void, Never>?
    private var didStart = false

    /// - Parameters:
    ///   - folderURL: directory to watch. Must exist and be a directory.
    ///   - stableDuration: how long `(size, mtime)` must be unchanged before
    ///     a file is considered ready. Defaults to PRD-conforming 2 s.
    ///   - recheckInterval: interval between repeated polls while at least
    ///     one candidate file is still settling. Defaults to 1 s so we
    ///     usually emit within `stableDuration + recheckInterval`.
    ///   - ledger: idempotency ledger. Defaults to the on-disk one in
    ///     Application Support; tests inject a temp-file-backed instance.
    init(
        folderURL: URL,
        stableDuration: TimeInterval = 2.0,
        recheckInterval: TimeInterval = 1.0,
        ledger: ProcessedFilesLedger = ProcessedFilesLedger()
    ) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path(percentEncoded: false), isDirectory: &isDir) else {
            throw WatcherError.folderDoesNotExist(folderURL)
        }
        guard isDir.boolValue else {
            throw WatcherError.folderNotADirectory(folderURL)
        }
        self.folderURL = folderURL
        self.detector = FileReadinessDetector(stableDuration: stableDuration)
        self.ledger = ledger
        self.recheckInterval = recheckInterval
    }

    /// Begin monitoring. Returns a single-subscriber `AsyncStream<URL>` that
    /// yields every URL the watcher deems ready and not-yet-processed.
    /// Throws if monitoring couldn't be set up, or if `start()` was already
    /// called.
    func start() throws -> AsyncStream<URL> {
        if didStart { throw WatcherError.alreadyStarted }
        didStart = true

        // `open(_:_:_:)` with `O_EVTONLY` opens the directory for event
        // notification only — we never read from this fd directly.
        let fd = open(folderURL.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else {
            throw WatcherError.cannotOpenForMonitoring(folderURL, errno: errno)
        }
        self.fileDescriptor = fd

        let queue = DispatchQueue(label: "com.toshonivc.jot.watcher", qos: .utility)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        self.dispatchSource = src

        let (stream, continuation) = AsyncStream.makeStream(of: URL.self)
        self.continuation = continuation

        src.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.handleFolderEvent()
            }
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        src.resume()

        // Initial sweep — catches any files already present when we start.
        Task { [weak self] in
            await self?.handleFolderEvent()
        }

        Log.watcher.info("FolderWatcher started on \(self.folderURL.path(percentEncoded: false), privacy: .public)")
        return stream
    }

    /// Tear down monitoring. The `AsyncStream` returned by `start()` will end.
    func stop() {
        recheckTask?.cancel()
        recheckTask = nil
        continuation?.finish()
        continuation = nil
        dispatchSource?.cancel()
        dispatchSource = nil
        fileDescriptor = -1
        didStart = false
        Log.watcher.info("FolderWatcher stopped on \(self.folderURL.path(percentEncoded: false), privacy: .public)")
    }

    // MARK: - Event handling

    private func handleFolderEvent() async {
        do {
            let candidates = try listCandidates()
            var anyStillSettling = false
            let now = Date()

            for url in candidates {
                guard let snap = snapshot(of: url) else { continue }
                let isReady = await detector.observe(url: url, snapshot: snap, at: now)

                if isReady {
                    if await ledger.contains(url) {
                        Log.watcher.info("Skipping already-processed file \(url.lastPathComponent, privacy: .public)")
                    } else {
                        do {
                            try await ledger.record(url)
                            continuation?.yield(url)
                            Log.watcher.info("Emitted ready file \(url.lastPathComponent, privacy: .public)")
                        } catch {
                            Log.watcher.error("Failed to record ledger entry for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                } else if await detector.snapshot(for: url) != nil,
                          await !detector.hasEmitted(url) {
                    anyStillSettling = true
                }
            }

            if anyStillSettling {
                scheduleRecheck()
            }
        } catch {
            Log.watcher.error("Folder event handling failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleRecheck() {
        // Only one outstanding recheck at a time.
        recheckTask?.cancel()
        let interval = recheckInterval
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.handleFolderEvent()
        }
    }

    private func listCandidates() throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        )
        // Resolve symlinks so downstream callers (and the ledger) see
        // canonical paths — `/var` resolves to `/private/var` on macOS, and
        // we don't want the same file flowing through as two different URLs.
        return contents
            .map { $0.resolvingSymlinksInPath() }
            .filter { SupportedAudioType.isCandidate($0) }
    }

    private func snapshot(of url: URL) -> FileSnapshot? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let size = values.fileSize.map(UInt64.init),
              let mtime = values.contentModificationDate
        else { return nil }
        return FileSnapshot(size: size, modificationDate: mtime)
    }

    deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }
}
