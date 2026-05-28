# Changelog

Versions are tagged from `main` (`v0.1.0`, `v0.1.1`, …) and built/signed by
`.github/workflows/release.yml`. The user-visible Sparkle dialog reads its
release notes from the `<description>` element in `docs/appcast.xml`, not
this file — this is the long-form humans-only log.

## v0.4.1 — Recording starts on hotkey press

Removes the friction where the recording hotkey opened a modal prompt
*before* Audio Hijack started capturing — you'd press the shortcut at
the top of a meeting and miss the first sentence while typing the
meeting name. Now the hotkey runs the start Shortcut immediately and
the metadata prompt appears alongside, to be filled in whenever you
get a chance during the meeting.

- **Recording-first hotkey.** Pressing the hotkey runs the AH start
  Shortcut as the very first thing; the menu bar flips to recording
  with a "Recording…" placeholder. A non-blocking metadata prompt
  appears so meeting name + organization + per-meeting context can be
  filled in while the meeting is already being captured.
- **Skip is supported.** The prompt's secondary button is "Skip" (was
  "Cancel"). Skipping leaves the recording running with no metadata —
  the file processes with the audio basename and no compiled context,
  same as a recording that wasn't kicked off via Jot.
- **Snapshot timestamping.** `MeetingContextStore.recordStarted` is
  stamped with the original recording-start timestamp (captured the
  moment the AH start Shortcut fired) so the pipeline's time-window
  guard still matches the audio file Jot picks up, even when the user
  takes a minute to fill in the prompt.
- **Internal refactor.** `AudioHijackController.toggleRecording` is
  split into single-purpose `startRecording(...) -> Date`,
  `stopRecording(...)`, and `collectMetadata(...)` — the old toggle
  shape couldn't model "started without metadata, metadata arrives
  later." Callers (`HotkeyCoordinator.fireBuiltInAudioHijack` and
  `testRecordingNow`) compose the three methods.

## v0.4.0 — Claude Code meeting notes + date-stamped Notion pages

Optional post-Notion routine trigger that asks a Claude Code routine to
fill in the empty Meeting Notes toggle, plus a small Notion improvement
that stamps today's date onto every created page.

- **New Settings → Claude Code section.** Master toggle, routine fire
  endpoint URL, bearer token (Keychain-backed, separate account from
  the transcription and Notion tokens), optional extra instruction text
  appended as the routine body's `text`, plus an in-app setup guide and
  test checklist. Validation distinguishes disabled / setup needed /
  ready and reminds the user that Notion must also be configured.
- **Strict trigger order** (PRD §4.3): transcript → Notion page →
  routine fire. The routine is only fired when the Notion write
  actually succeeded; a Notion failure short-circuits with
  `Notes: skipped (notionNotReady)` on the audit row so the user knows
  why no notes were generated.
- **Single-retry fire client.** `URLSession`-backed
  `ClaudeCodeRoutineClient` sends the PRD §4.4 contract verbatim
  (`Authorization: Bearer …`, `anthropic-version: 2023-06-01`,
  `anthropic-beta: experimental-cc-routine-2026-04-01`,
  `Content-Type: application/json`, body `{"text": "…"}`). Transport
  errors retry once; status-coded errors surface immediately and never
  affect the rest of the pipeline.
- **Audit log shows the outcome.** Success rows render
  `Notes: fired` in blue; failures render a red triangle with the error
  message in a tooltip. Disabled / no-Notion-page cases stay silent so
  default-user UX isn't nagged.
- **Notion pages get today's date.** When the configured Notion
  database has a `date`-typed property, Jot now stamps it with today's
  date (`YYYY-MM-DD`, user-local time zone) on page creation. Databases
  without a date column behave exactly as before.
- **Schema bump.** `AuditLogEntry` schemaVersion 3 → 4 (adds
  `claudeCodeStatus`). v1–v3 entries on disk decode cleanly with
  `claudeCodeStatus = nil`.

## v0.3.0 — Notion meeting creation

Optional delivery bridge that creates a new page in a configured Notion
database after every successful transcript.

- **New Settings → Notion section.** Toggle ("Create a Notion page after
  each transcript"), integration token (Keychain-backed, separate
  account from the transcription API key), target database ID, and a
  Test connection button that runs `describeDatabase` against the
  configured account.
- **Three predefined toggle sections** are created on every page, in
  the PRD-mandated order: Meeting Notes (intentionally empty for the
  user to fill in), Meeting Transcript (the Jot transcript), Additional
  Context (the compiled `prompt` from v0.2.x). Section names are not
  configurable.
- **Never blocks the core pipeline.** Notion is fired as a background
  task *after* the success audit entry, transcript, audio move, and
  `context.md` write all complete. A failed Notion write leaves all of
  those untouched and lands as a tooltip on the audit row.
- **Audit log shows the outcome.** Success rows render a tappable
  "Notion page" link that opens the new page in the browser; failures
  render a red triangle with the error message in a tooltip. Disabled
  users see no extra UI noise.
- **Schema bump.** `AuditLogEntry` schemaVersion 2 → 3 (adds
  `notionStatus`). v1 and v2 entries on disk decode cleanly with
  `notionStatus = nil`.
- **Notion REST, not MCP.** Despite "MCP" in the PRD wording, the
  shipping implementation talks to `api.notion.com` directly via
  `URLSession` — no third-party SDK, no sidecar process, no extra
  sandbox entitlements. The label in Settings is "Notion connection"
  to keep the door open for an MCP-shaped transport later if needed.

## v0.2.1 — Start-flow polish

Two small fixes to the v0.2.0 Context flow, per first-day usage:

- **Start-meeting prompt no longer surfaces the main window.** Pressing
  the recording hotkey while the main window was open in the
  background would re-front the main window alongside the new
  meeting prompt. The prompter now orders any visible normal Jot
  windows out before activating the app, so the only Jot UI on
  screen during start is the prompt itself.
- **Meeting folders are prefixed with a timestamp** in
  `yyyy.MM.dd - HH.mm` form so Finder sorts them chronologically.
  A "Standup" meeting recorded at 15:30 on 2026-05-28 now files
  under `2026.05.28 - 15.30 - Standup/`, with matching transcript
  + audio filenames inside. Only applies to the Jot-rename path
  (snapshot consumed); files that fall outside any recording
  window keep their Audio-Hijack-stamped name.

## v0.2.0 — Context

First feature beyond the foundation app: per-organization profiles plus
per-meeting context that flow into the Whisper transcription request as
the `prompt` parameter (up to 224 tokens; we budget 800 chars by
default) and into the output folder as a `context.md` artifact for
reproducibility.

What's new:

- **New "Context" tab** (4th sidebar item) for CRUD on organization
  profiles: name, company, staff, projects, glossary, acronyms,
  freeform notes, default-for-new-meetings toggle.
- **Meeting-start prompt** now asks for name + organization + optional
  meeting-specific context. Default org pre-selected; "No Organization"
  remains a first-class choice for private calls.
- **Edit current meeting…** entry in the menu-bar dropdown opens a
  floating editor while a recording is active; edits apply to the
  compiled prompt the pipeline will send.
- **Pipeline** compiles a deterministic prompt per PRD §6 (system
  prefix → org identity → staff → projects → glossary/acronyms → org
  notes → meeting name → meeting-specific context), trimming and
  deduping case-insensitively within each list, with the lowest-
  priority sections dropped first under budget pressure.
- **Output folder** gets a `context.md` next to the transcript when a
  prompt was sent — the exact compiled string, wrapped in a fenced
  block. Failed file-move rolls back the transcript and `context.md`
  together.
- **Audit log** rows surface "Context: yes (Acme)" / "Context: no" and
  the entry schema is bumped to v2 (`contextAttached`,
  `organizationName`). Legacy v1 rows on disk decode cleanly.

Backwards-compat: users with zero organizations see the new Context
tab but no behavior change in their existing transcription flow — the
prompt field is omitted from the request when there's nothing to send,
and no `context.md` is written.

## v0.1.7 — Bootstrap at process launch

Fixes the menu-bar icon sitting at "Not yet configured" after Login-Item
autostart until the user manually opened the main window.

Cause: `pipeline.bootstrap()` and `hotkey.bootstrap()` were called from a
`.task` modifier on `MainWindow`. Because `LSUIElement = YES`, the window
isn't shown at launch, so the modifier never fired. Moved both calls
(plus the `launchOnStartup` reapply) into `JotApp.init()` so they run
unconditionally at process launch.

## v0.1.6 — App icon

First real Dock/Launchpad icon. Replaces the empty `AppIcon.appiconset`
placeholder with a custom mark — warm amber-to-coral squircle, white "j"
glyph with a three-bar equalizer tittle (audio → notes). Menu-bar icon is
unchanged.

Source SVG lives at `Branding/logo.svg`; PNGs are regenerated by
`swift scripts/build-icons.swift` (no external deps — uses NSImage's
built-in SVG rasterizer).

## v0.1.5 — Sparkle round-trip smoke test

End-to-end verification that an auto-update lands cleanly through the in-app
**Settings → Check for Updates…** flow now that the `-spki` entitlement is in
place (v0.1.4). No code changes.

## v0.1.4 — Sparkle Installer Interaction entitlement

Added the missing `$(PRODUCT_BUNDLE_IDENTIFIER)-spki` mach-lookup
allow-list entry. Together with `-spks` (Status) and `-spkp` (Progress)
added in v0.1.2, the sandboxed main app can now talk to all three of
Sparkle's update helper services. v0.1.0 → v0.1.4 had to be installed
manually because earlier builds' entitlements were missing one of the
three names.

## v0.1.2 — First Sparkle entitlements

Added `-spks` + `-spkp` mach-lookup entitlements (turned out `-spki` was
also required — see v0.1.4).

## v0.1.1 — Sandbox-safe Shortcuts invocation + sidebar version footer

- Replaced `/usr/bin/shortcuts` Process spawn with
  `NSWorkspace.open(shortcuts://run-shortcut?name=…&input=…)`. The CLI
  crashed inside our sandbox; URL-scheme invocation hops out of the
  container cleanly.
- Added sidebar version footer with an "Update available: vX.Y" badge
  when Sparkle's background check has found a newer release.

## v0.1.0 — First public release

Initial production build. Hotkey-triggered recording via user-authored
Apple Shortcuts, transcription via OpenAI-compatible API, Audit Log,
Transcripts browser, App Sandbox, ad-hoc signed, auto-update via Sparkle
+ GitHub Pages-hosted appcast.
