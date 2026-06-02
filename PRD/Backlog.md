# Backlog

Loose, unprioritized ideas. Promote an item to a PRD + implementation plan when it's next up.

## Pipeline / performance

- [ ] Accelerate transcription by starting transcription when the first file arrives, instead of waiting until all files are ready before sending them to the transcription service.

## Transcript quality

The biggest near-term lever. A real Dutch meeting came back with ~5 min of leading
silence transcribed as the prompt itself ("Names and terms used in this audio",
"Ellen Mees, Brecht Thijs, Niels Vermaut Acronyms"), plus Whisper training-data
hallucinations on silence ("Ondertitels ingediend door de Amara.org gemeenschap"),
repetition loops ("is their / is their", "so so so"), and English gibberish in
low-signal regions. Classic Whisper-on-silence behavior. Fixes, cheapest first:

- [ ] **Pin the language.** The meeting was Dutch but no `language` was sent, so
  auto-detect drifted to English garbage in quiet stretches. Add a per-meeting (or
  per-org default) language setting and pass `language` to the transcription request.
- [ ] **Filter low-confidence segments.** `verbose_json` already returns
  `no_speech_prob`, `avg_logprob`, and `compression_ratio` per segment. Capture them
  on `Segment` and drop segments where `no_speech_prob` is high / `avg_logprob` is
  very low / `compression_ratio` is abnormal (repetition). Kills most of the junk
  with zero audio processing. **Timeline-neutral** — it removes output segments without
  shifting audio timing, so it does not break screenshot/timestamp alignment (see the
  trimming caveat below). Prefer this and the prompt fix over trimming.
- [ ] **Drop prompt echoes.** During silence Whisper parrots the prompt back. We
  *have* the exact compiled prompt (`MeetingContextSnapshot.resolvedCompiledContext`),
  so any segment that's a substring of it can be dropped with certainty. Also strip a
  known-hallucination denylist (Amara.org subtitle credits, "Transcribed by OpenAI",
  etc.).
- [ ] **Reconsider prompt phrasing.** "Transcription context. Names and terms used in
  this audio:" reads as natural prose, which is exactly what gets emitted as if spoken.
  A bare comma-separated term list is less echo-prone.
- [ ] **VAD / silence trimming before upload.** Root-cause fix: trim leading/trailing
  silence so there's nothing for Whisper to hallucinate over. Also cuts cost and
  latency. Bigger lift than the post-filters above. **Caveat — clock invariant:**
  trimming shifts every downstream timestamp earlier by the removed duration, which
  desyncs anything keyed to wall-clock recording time (the screenshot-context feature
  below relies on this). Rule: the transcript's public timestamps must always live on
  the *original recording clock* — record each cut interval and add it back before
  timestamps are exposed or merged (folds into the same cumulative-offset map the
  multi-part merge already builds). Trim head/tail only (not internal silence — not the
  culprit in the observed failure); a single constant offset per part is trivially
  invertible, and the silent lead-in has no screenshots worth keeping anyway.

## Speaker identification

Whisper does not diarize; speaker labels must come from elsewhere and be merged in
(we already have segment-level timestamps to merge against). Tiers, cheapest first:

- [ ] **Multi-track recording (Audio Hijack).** If mic and meeting-app output are
  recorded on separate tracks, "me vs them" separation is free — transcribe each track
  and merge by timestamp. Doesn't separate individuals within a remote channel; useless
  for single-mic in-person. Check whether this covers most real meetings before
  building anything heavier.
- [ ] **Diarizing transcription provider.** The provider layer (`RotatingTranscriber`,
  `Provider`) can take a backend that returns speaker labels natively (Deepgram
  `diarize=true`, AssemblyAI, Speechmatics). One call, labeled words back.
- [ ] **Decoupled diarization + merge.** Keep Whisper for words; run a separate
  diarization pass (pyannote / WhisperX local, or an API) that returns speaker *turns*;
  assign each Whisper segment to the most-overlapping turn (pure-Swift interval join).
- [ ] **LLM name resolution.** Diarization only yields "Speaker 0/1/2". Feed the
  labeled transcript + `Organization.staffNames` roster to an LLM to map anonymous
  labels to real names using the roster + content cues. Natural reason to add the
  summarization/LLM step we don't yet have.

## Screenshots as meeting context

A meeting has a time axis, so screenshots are timestamped events, not one blob. Two
distinct uses with two different processing paths — don't conflate them:

- [ ] **OCR'd terms -> transcription prompt.** Capture screenshots during recording,
  OCR locally with the Vision framework (`VNRecognizeTextRequest` — free, on-device, no
  network/sandbox issue), extract novel proper nouns, dedupe against the roster/glossary,
  inject into the compiled Whisper prompt as another budget-aware `ContextCompiler`
  section. Fixes the exact-spelling problem (names/jargon on a shared doc). All
  screenshots are on disk before transcription runs, so timing works out.
- [ ] **Timestamped vision descriptions -> meeting notes.** LLM vision descriptions of
  screenshots, interleaved with the transcript at their capture time (the
  `TimestampedTranscriptFormatter` already renders `[HH:MM:SS]`; descriptions slot in as
  a new line type). Gives notes the visual referent for "as you can see on screen".
  Attach the images to the Notion page so the Claude Code routine can use them.
  **Depends on the clock invariant:** screenshots align by wall-clock recording time, so
  this only works if transcript timestamps stay on the original recording clock. Any
  silence-trim (above) must be inverted before alignment, or this drifts. Build the
  wall-clock<->transcript mapping as a shared concern, not per-feature.
- [ ] **Capture trigger.** Start with a manual hotkey ("mark this moment + screenshot")
  reusing the M4 global-hotkey machinery — highest signal-to-noise, least disk/privacy
  cost. Automatic capture (periodic during recording, and/or on frontmost-app switch as
  a "topic changed" proxy) is a v2.
- [ ] **Decisions to make up front:** ScreenCaptureKit needs the Screen Recording TCC
  grant (new permission, brushes the "stay sandboxed" rule); local Vision OCR keeps data
  on-device, but sending screenshots to an LLM means images leave the machine — consider
  OCR-for-transcription always-on, LLM-vision-for-notes opt-in.
