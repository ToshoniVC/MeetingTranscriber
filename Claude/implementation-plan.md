# Jot — Implementation Plan: Streaming Transcription (v0.6.0)

Derived from [../PRD/StreamingTranscription_PRD_2026_06_02.md](../PRD/StreamingTranscription_PRD_2026_06_02.md).
Transcribe each Audio Hijack part as it's finalized *during* recording, buffer the result, and at
Stop transcribe only the final part before assembling — so the transcript lands shortly after Stop.

Scope guard: streaming is a pure optimization layered onto the existing batch path. The single-
file path, `FileOrganizer`, Notion, and Claude Code stages are untouched. On any failure or
restart, behavior degrades to the current v0.5.x end-of-meeting transcription.

---

## 0. Guiding constraints

- **Additive and reversible.** If the streaming buffer is empty for a part (failed, cancelled,
  never streamed), assembly transcribes it fresh — identical to today.
- **The watcher already guarantees finalized parts.** No new file-stability logic; rely on the
  existing `FileReadinessDetector`.
- **Output equivalence.** The assembled transcript must equal what the non-streaming path would
  produce for the same audio (same order, same merge, same per-part filtering).
- **The streaming buffer's only consumer is `processBatch`.** `process(url:)` (single-file /
  manual upload) never sees a streamed part, so it stays unchanged.

---

## Phase A — Accumulator signals streamability

`Jot/Features/Pipeline/MeetingBatchAccumulator.swift`

- **A.1** Add an `IngestOutcome` returned from `ingest(_:creationDate:now:)`:
  ```swift
  enum IngestOutcome: Sendable {
      case streamable(prompt: String?)  // buffered into an ACTIVE (recording) session
      case buffered                     // buffered, but session already stopped → leave for flush
      case emittedSingle                // not part of any session
  }
  ```
- **A.2** In `ingest`: when the file matches an active session (`session.stoppedAt == nil`),
  buffer it and return `.streamable(prompt:)`, where `prompt` is the session snapshot's
  `resolvedCompiledContext` normalized to `nil` when empty (matching `processBatch`'s prompt
  logic). When it matches a stopped-but-still-settling session, return `.buffered`. Otherwise emit
  the single as today and return `.emittedSingle`.
- **A.3** No change to `flushNow` / `MeetingBatch` — the emitted batch still carries the original
  part URLs in chronological order; those URLs are the buffer keys.

**Tests** (`MeetingBatchAccumulatorTests`):
- ingest during active session → `.streamable` with the expected prompt.
- ingest after `noteRecordingStopped` (within settle window) → `.buffered`.
- ingest with no session → `.emittedSingle`.
- prompt is `nil` when the snapshot's compiled context is empty.

---

## Phase B — Pipeline buffers and runs streamed transcriptions

`Jot/Features/Pipeline/ProcessingPipeline.swift`

- **B.1** Actor state: `private var streamingTranscriptions: [URL: Task<TranscriptionResult, Error>] = [:]`.
- **B.2** In `routeFromWatcher(_:)`, switch on the new `ingest` outcome. On `.streamable(prompt)`
  call `startStreamingTranscription(url:prompt:)`; other cases behave as today.
- **B.3** `startStreamingTranscription(url:prompt:)`:
  - Guard `streamingTranscriptions[url] == nil` (no double-start).
  - Store `Task { try await self.runTranscription(audio: url, prompt: prompt) }`.
  - Log start at info ("streaming part while recording"); never log the prompt.
  - The task runs on the pipeline actor and suspends at the network `await`, so multiple stream
    tasks interleave without blocking watcher event handling.
- **B.4** Cancellation: add `cancelStreamingTranscriptions()` that cancels every task and clears
  the map; call it from the pipeline's `stop()` / teardown so a settings-change restart doesn't
  leak in-flight uploads.

**Tests** (`ProcessingPipelineStreamingTests`, new): assert a streamed task is created when a part
is routed during an active session; assert `stop()` cancels in-flight tasks.

---

## Phase C — Assembly reuses streamed results

`Jot/Features/Pipeline/ProcessingPipeline.swift` — `processBatch(_:)`

- **C.1** Reorder so transcription happens **before** rename: resolve parts → collect results →
  rename/move → merge → organize. (Today it renames then transcribes; streamed tasks ran on the
  original URLs, and we must not move a file mid-upload.)
- **C.2** Result collection, per part in `batch.parts` order:
  ```swift
  if let task = streamingTranscriptions.removeValue(forKey: originalURL) {
      do { result = try await task.value }
      catch { result = try await runTranscription(audio: resolved, prompt: prompt) } // fresh fallback
  } else {
      result = try await runTranscription(audio: resolved, prompt: prompt)           // e.g. final part
  }
  ```
  Apply the existing inter-part delay only between *fresh* transcriptions (streamed ones were
  already spaced out).
- **C.3** `defer`-clean any remaining buffer entries for this batch's URLs (covers early-throw
  paths) so the map can't leak across meetings.
- **C.4** Everything downstream (`merging`, `renameParts`, `organize`, audit, Notion, Claude Code)
  is unchanged.

**Tests** (`ProcessingPipelineStreamingTests`): with a call-counting mock transcription client —
- multi-part meeting where parts 1…N−1 were streamed: client is called exactly once per part
  (no double-transcription), final part transcribed at assembly, merged transcript matches the
  non-streaming baseline.
- a streamed part whose task fails: it's re-transcribed at assembly and the transcript is still
  complete.
- single-file `.single` path: streaming buffer untouched, behavior identical to today.

---

## Phase D — Docs, version, ship

- **D.1** Confirm the in-code references (this plan + PRD) and `CLAUDE.md` Active-PRD/plan pointers
  are updated; Manual Upload PRD/plan moved to archive.
- **D.2** Bump `MARKETING_VERSION` → `0.6.0` in `Jot/Config/Release.xcconfig`.
- **D.3** Full `xcodebuild test` green. PR → CI → squash-merge → tag `v0.6.0` → release pipeline.

---

## Risk register

| Risk | Mitigation |
|------|------------|
| File moved out from under an in-flight upload | Collect all results before `renameParts` (C.1) |
| Mid-meeting restart leaves orphaned tasks | `cancelStreamingTranscriptions()` on stop (B.4); empty buffer at flush → fresh transcription |
| Double-transcription of a part | `removeValue` on consume (C.2) + no-double-start guard (B.3); single path never reads the buffer |
| Streamed result diverges from fresh (ordering/duration) | Reassemble strictly in `batch.parts` chronological order; `merging` unchanged; equivalence test (C.3) |
| Provider rate limit | Streamed parts naturally spaced; inter-part delay retained for fresh transcriptions |
