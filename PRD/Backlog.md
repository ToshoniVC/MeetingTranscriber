# Backlog

Loose, unprioritized ideas. Promote an item to a PRD + implementation plan when it's next up.

## Pipeline / performance

- [x] **Accelerate transcription by starting transcription when the first file arrives**, instead of
  waiting until all files are ready. Shipped as streaming transcription in v0.6.0
  ([`PRD/StreamingTranscription_PRD_2026_06_02.md`](StreamingTranscription_PRD_2026_06_02.md)).

## Transcript quality

The biggest near-term lever. A real Dutch meeting came back with ~5 min of leading
silence transcribed as the prompt itself ("Names and terms used in this audio",
"Ellen Mees, Brecht Thijs, Niels Vermaut Acronyms"), plus Whisper training-data
hallucinations on silence ("Ondertitels ingediend door de Amara.org gemeenschap"),
repetition loops ("is their / is their", "so so so"), and English gibberish in
low-signal regions. Classic Whisper-on-silence behavior.

**Baseline measured 2026-10-12** over the ten most recent meetings in the Notion
"Meeting Notes" database: roughly one segment in eight was prompt echo or Whisper
boilerplate that the confidence filter let through (43% in the worst meeting), the
wrong organization's glossary was attached on four of ten, two meetings opened with
fabricated Swedish/Norwegian because no language was pinned, and the merged on-disk
`.json` had dropped the per-segment confidence fields, so none of it was measurable
from the artifacts. The first wave of fixes shipped on the `transcript-quality`
branch (2026-10-12); against the same twelve transcripts the new filter removes
750 of 5,110 segments (14.7%) with no false positives in the spot-checked meeting.

- [x] **Pin the language.** Per-meeting picker (start prompt, in-meeting editor, Manual
  Upload prompt) → organization default → app-wide default (ships as `nl`, Context →
  General) → auto-detect. Sent as the `language` form field. Failed rows remember the
  pinned language so Retry replays it (`AuditLogEntry` schema v8).
- [x] **Filter low-confidence segments.** `TranscriptionSegmentFilter` (v0.5.6) drops
  segments on `no_speech_prob` / `avg_logprob` / `compression_ratio`.
- [x] **Drop prompt echoes and boilerplate.** `TranscriptArtifactFilter` drops segments that
  are the glossary or near-misses of it ("Caleidos", "Ttijs", "TnT is a"), known outro and
  subtitle boilerplate, bare URLs, symbol-only lines, and runs of identical short
  segments; strips a *repeated* glossary lead-in ("TnT TnT TnT I already…"). Matches the
  glossary only, never the previous-part continuation. Timeline-neutral.
- [x] **Reconsider prompt phrasing.** `ContextCompiler` now emits one flat comma list of
  terms (no "Organization:" / "Meeting:" / "Notes:" lines, no freeform notes, 300-char
  budget, empty default lead-in), and each part's prompt carries the previous part's
  last ~400 characters as continuation — what the Whisper `prompt` field is for.
- [x] **VAD / silence trimming before upload — head and tail.** `SilenceTrimmer` cuts
  leading/trailing silence when ≥5 s would go (adaptive threshold, 1 s padding, never
  skips a part), re-encodes only trimmed parts to 16 kHz mono AAC, and the pipeline adds
  the head cut back to every timestamp and restores the original duration before merge,
  so the recording clock is preserved. Internal silence is deliberately left alone (see
  the clock invariant below).
- [x] **Keep the diagnostics.** Merged results carry the three confidence fields, the
  reported language and a dropped-segment count into the on-disk `.json`; the audit
  success row shows `· nl · 12% filtered (41/370)`.
- [ ] **Internal silence.** The head/tail trim leaves mid-meeting voids (30–90 s between
  speech) that still produce a hallucination per silent window; the artifact filter
  catches most of them after the fact. Cutting them before upload needs a cumulative
  offset map so every public timestamp stays on the *original recording clock* (the
  screenshot-context feature below depends on this). Fold into the multi-part merge's
  existing offset bookkeeping; never expose trimmed-clock timestamps.
- [ ] **Organization picker defaults.** Four of ten recent meetings went out with the wrong
  org's glossary because one org is `isDefault` and the start prompt preselects it.
  Default to "No Organization" or last-used instead, and show the compiled glossary in the
  start prompt so a TnT list on an Alpex call is visible before it ships.
- [ ] **Mixed echo segments.** Segments that weld a glossary term onto real words ("Ttijs TnT
  is a part of the Ttijs team", "Qarakter is a big company that…") are kept on purpose —
  the filter never deletes a sentence that might be real. The notes routine already reads
  through them; a cheap LLM clean-up pass over the filtered transcript could remove the
  rest if it keeps bothering the notes.
- [ ] **Model / provider bake-off.** On three real recordings, compare Groq `whisper-large-v3`
  (today) against: OpenAI `whisper-1` with the language pinned (v2 hallucinates less than
  v3); `gpt-4o-transcribe` (far fewer hallucinations, better code-switching, supports
  `prompt` + `language`, but `json` only — no segments or duration, so timestamps and merge
  offsets would have to come from the audio files); `gpt-4o-transcribe-diarize`
  (`diarized_json` with start/end/speaker per segment plus known-speaker references, no
  `prompt`); ElevenLabs Scribe v2 / Deepgram Nova-3 / AssemblyAI (diarization + code-
  switching, need a non-OpenAI-compatible adapter in the provider layer). Score Dutch and
  English separately.
- [ ] **Quality trend.** The audit row now carries `% filtered`; surface it over time (per
  org, per week) so a regression in recording hygiene or a provider change is visible
  without reading transcripts.

## Speaker identification

Whisper does not diarize; speaker labels must come from elsewhere and be merged in
(we already have segment-level timestamps to merge against). Tiers, cheapest first:

- [ ] **Multi-track recording (Audio Hijack).** If mic and meeting-app output are
  recorded on separate tracks, "me vs them" separation is free — transcribe each track
  and merge by timestamp. Doesn't separate individuals within a remote channel; useless
  for single-mic in-person. Check whether this covers most real meetings before
  building anything heavier.
- [ ] **Diarizing transcription provider.** The provider layer (`RotatingTranscriber`,
  `Provider`) can take a backend that returns speaker labels natively (OpenAI
  `gpt-4o-transcribe-diarize`, Deepgram `diarize=true`, AssemblyAI, Speechmatics,
  ElevenLabs Scribe v2). One call, labeled words back. `gpt-4o-transcribe-diarize` also
  accepts known-speaker reference audio, so a sample of the user's voice would label
  them by name. Overlaps with the bake-off above.
- [ ] **Decoupled diarization + merge.** Keep Whisper for words; run a separate
  diarization pass (pyannote / WhisperX local, or an API) that returns speaker *turns*;
  assign each Whisper segment to the most-overlapping turn (pure-Swift interval join).
- [ ] **LLM name resolution.** Diarization only yields "Speaker 0/1/2". Feed the
  labeled transcript + `Organization.staffNames` roster to an LLM to map anonymous
  labels to real names using the roster + content cues. The Claude Code notes routine
  already attempts this from content alone; labels would make it reliable.

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
  this only works if transcript timestamps stay on the original recording clock. The
  head/tail silence trim already honours this (offsets are added back before anything
  downstream sees a timestamp); any internal-silence trim must do the same. Build the
  wall-clock<->transcript mapping as a shared concern, not per-feature.
- [ ] **Capture trigger.** Start with a manual hotkey ("mark this moment + screenshot")
  reusing the M4 global-hotkey machinery — highest signal-to-noise, least disk/privacy
  cost. Automatic capture (periodic during recording, and/or on frontmost-app switch as
  a "topic changed" proxy) is a v2.
- [ ] **Decisions to make up front:** ScreenCaptureKit needs the Screen Recording TCC
  grant (new permission, brushes the "stay sandboxed" rule); local Vision OCR keeps data
  on-device, but sending screenshots to an LLM means images leave the machine — consider
  OCR-for-transcription always-on, LLM-vision-for-notes opt-in.
