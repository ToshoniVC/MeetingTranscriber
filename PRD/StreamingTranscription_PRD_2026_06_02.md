# Jot — PRD: Streaming Transcription (v0.6.0)

Status: **Active** · Target milestone: **v0.6.0** · Authored 2026-06-02

## 1. Problem

Audio Hijack splits a long meeting into multiple files ("parts") as it records. Today Jot
buffers every part until the meeting ends, and only *then* transcribes all of them — serially
— before assembling one transcript. For a 60-minute meeting split into, say, 6 parts, the user
waits after pressing Stop for all 6 parts to upload and transcribe end-to-end. The transcript
lands minutes after the meeting is over.

But parts 1…N−1 are already finished long before the meeting ends — Audio Hijack closes each
part the instant it rolls to the next one. We're sitting on finished audio we could already be
transcribing.

## 2. Goal

Transcribe each part **as soon as it is finalized, while the meeting is still recording**, and
buffer the per-part result. When the user stops, only the **final** part (the one still being
written at Stop) needs to upload and transcribe. The full transcript becomes available shortly
after Stop instead of minutes later.

Concretely: *time-to-transcript after Stop* drops from "sum of all parts" to "the last part +
assembly."

## 3. Non-goals

- **No change to single-file meetings.** A recording that never splits is one file that grows
  until Stop; there's nothing to stream ahead. That path is untouched.
- **No change to manual uploads.** Manually-dropped multi-file uploads arrive all-at-once, not
  as a live recording; speeding those up is a separate optimization (out of scope, see Backlog).
- **No new transcription accuracy work.** Per-part hallucination filtering (v0.5.6) already runs
  inside each transcription call and is unchanged.
- **No persistence of partial results across app restarts.** In-flight streaming is in-memory;
  an app/pipeline restart mid-meeting cleanly falls back to the current end-of-meeting behavior.
- **No UI surface** beyond what already exists. (A future "transcribing 3/6 parts…" indicator is
  a possible fast-follow, not this milestone.)

## 4. Key insight that makes this safe

The `FolderWatcher`'s readiness detector only emits a file once its `(size, mtime)` has been
stable for ~2s. A part that Audio Hijack is *actively writing* keeps growing, so it is never
emitted until AH closes it (by rolling to the next part, or by the user stopping). **Therefore,
by the time a part reaches the accumulator it is already finalized and safe to transcribe.** No
new "is this file done?" logic is required.

## 5. Behavior

### 5.1 The streaming rule

When a part is ingested into an **active** recording session (the session's `stoppedAt` is still
`nil`), kick off its transcription immediately and buffer the in-flight result keyed by the
part's URL. When the session has already stopped at ingest time, leave the part for end-of-
meeting assembly as today.

This naturally draws the line in exactly the right place:

| Part | When it finalizes / is ingested | Streamed? |
|------|----------------------------------|-----------|
| 1 … N−1 | When AH rolls to the next part — **during** recording | Yes |
| N (final) | ~2s after Stop — session already stopped | No → transcribed at assembly |
| Lone single-file | Grows until Stop, ingested post-stop | No → unchanged single-file path |

### 5.2 Assembly (at the existing settle/flush)

`processBatch` collects results in the accumulator's existing chronological part order:

- For each part, if a streamed result exists, **await** it (most are already done).
- For any part without one (normally just the final part), transcribe it now.
- Merge via the existing `TranscriptionResult.merging(...)`, then file / Notion / Claude Code
  exactly as today.

Transcription results are collected **before** the audio files are renamed/moved, so no file is
relocated out from under an in-flight upload.

### 5.3 Failure & degradation policy

Streaming is a pure optimization. It must never introduce a failure mode the current design
doesn't already have:

- **A streamed part's transcription fails** (transient network, provider error): at assembly the
  awaited task throws and the part is **re-transcribed fresh** — identical to today's behavior.
- **Pipeline restarts mid-meeting** (e.g., settings change): the in-memory buffer is dropped and
  in-flight tasks cancelled; the long-lived accumulator still flushes at Stop and everything is
  transcribed fresh. Graceful fall-back to v0.5.x behavior.
- **A part is somehow ingested twice**: a second streaming task is never started for a URL that
  already has one.

### 5.4 Prompt / context

A streamed part uses the compiled prompt from the meeting's start-time snapshot — the same value
`processBatch` uses today (`batch.snapshot.resolvedCompiledContext`). Behavior is unchanged from
the current batch path. (Known pre-existing limitation, unchanged here: mid-meeting context edits
do not retroactively alter the prompt for a batched meeting.)

## 6. Success criteria

1. For a multi-part recorded meeting, parts 1…N−1 are transcribed before Stop; after Stop only
   the final part is uploaded/transcribed.
2. The assembled transcript is byte-for-byte equivalent to what the non-streaming path would have
   produced for the same audio (same merge, same order, same filtering).
3. Single-file meetings and manual uploads are unaffected.
4. A forced mid-meeting failure of an early part still yields a complete, correct transcript.
5. Rate-limit pressure does not increase (streamed parts are spaced out across the meeting).

## 7. Rate limits & footprint

Streaming spreads transcription requests across the meeting's duration rather than bursting them
all at Stop, so provider per-minute pressure is *lower*, not higher. The existing inter-part
delay still applies to any fresh transcriptions performed at assembly. Idle-CPU and memory
footprint are unchanged — the buffer holds a handful of `TranscriptionResult`s and `Task`
handles per meeting.

## 8. Open decisions (defaults chosen)

| Decision | Default | Rationale |
|----------|---------|-----------|
| Concurrency of streamed parts | Let the pipeline actor interleave them at `await` points | Parts are naturally minutes apart; no artificial serialization needed |
| Buffer keying | By original part `URL` | Stable, unique, available at ingest and at assembly before rename |
| Scope | Recorded meetings only | Manual uploads are a different (all-at-once) shape |
| Partial-result persistence | None (in-memory) | A restart mid-meeting is rare and degrades cleanly |
