# Jot — Implementation Plan: Create Notion Meeting

Derived from [`../PRD/CreateNotionMeeting_PRD_2026_05_28.md`](../PRD/CreateNotionMeeting_PRD_2026_05_28.md). This plan **extends the shipped v0.2.x app** (Add Context milestone — see archived [Add Context plan](archive/implementation-plan_addContext_v2026_05_28.md)) with an optional **delivery bridge** that creates a new page in a configured Notion database whenever Jot finishes a transcript. The page body contains exactly three toggle sections: Meeting Notes (empty), Meeting Transcript, Additional Context.

> The PRD scope is strictly "create the page and drop transcript + compiled context into predefined toggles." No summarization, no action items, no edits to content, no post-processing (PRD §3, §9).

---

## 0. Guiding constraints (from the PRD + standing rules)

- **Additive and opt-in.** When the Notion toggle is OFF (the default), the app behaves exactly as it does today — no extra requests, no extra files, no audit-log noise (PRD §4.1).
- **Never block the core pipeline.** Notion write failures must not affect transcription success or the on-disk artifacts (transcript, audio move, `context.md`). The pipeline reports success the instant `FileOrganizer.organize(...)` returns; the Notion write is a fire-and-forget side effect (PRD §6, §8 Acceptance #9).
- **Feature-Driven Design.** One new feature folder: `Features/Notion/`. The Pipeline calls into Notion via a small public surface (`NotionMeetingWriter` protocol); Notion code does not reach back into Pipeline / Transcription / MeetingContext beyond the typed inputs it's handed (`coding-instructions.md` §2).
- **Secrets stay in Keychain.** The Notion integration token (the credential the user pastes into Settings) lives in Keychain alongside the existing `apiKey`. Never UserDefaults, never plist, never a config file (`coding-instructions.md` §3, PRD §7).
- **Schema migrations.** New persisted settings carry `schemaVersion: Int` if they ever land in a Codable file. The current path piggybacks on `AppSettings` (UserDefaults primitives + Keychain string), which doesn't need migration code — see Phase A.
- **Tests in the same PR as the feature.** Unit + integration per `coding-instructions.md` §6, including a `URLProtocol` mock to assert the Notion request body has the exact three toggle sections in the exact order.
- **No new third-party SDK without justification.** Talk to Notion via `URLSession` against their public REST API. No `NotionClient` SPM package (`coding-instructions.md` §5 "Native APIs over libraries").

---

## 0.5 Decision: how do we actually talk to Notion?

The PRD says "Notion MCP connection" (PRD §2, §4.1). The literal reading is Model Context Protocol — i.e., spawn / connect to an MCP server and call Notion via its tool surface. **That's not the right shape for a native Swift menu-bar app**: there's no first-class Swift MCP client, integrating one would mean either a sidecar process or a bundled JS runtime, and the only thing we actually need is "create a page with three toggle blocks" — a single Notion REST call.

**Recommended path: Notion REST API directly from Swift via `URLSession`.** The user-facing label in Settings can still say "Notion connection" — the term is incidental to how we transport the request. This:

- Keeps the dependency footprint at zero (PRD §7, `coding-instructions.md` §5).
- Lets us mock cleanly with `URLProtocol` in tests (`coding-instructions.md` §6).
- Is the way every other macOS Notion integration works in practice.
- Is reversible — if a future feature genuinely needs MCP, we can introduce it then without throwing this work away.

This is called out explicitly in **Open question #1** below — confirm during Phase A kickoff before any code lands.

---

## 0.6 Folder additions

```
Jot/
├── Core/
│   └── Settings/
│       └── AppSettings.swift                  # extend: + notionEnabled, + notionDatabaseId,
│                                              #         + notionToken (Keychain-backed)
│
├── Features/
│   ├── Notion/                                 # NEW — the delivery bridge
│   │   ├── NotionMeetingWriter.swift           # protocol (public surface the pipeline depends on)
│   │   ├── NotionClient.swift                  # concrete impl: URLSession against api.notion.com
│   │   ├── NotionConfig.swift                  # struct: token + databaseId + apiVersion
│   │   ├── NotionPageBuilder.swift             # pure: (name, transcript, context) → NotionPagePayload
│   │   ├── NotionPagePayload.swift             # Encodable model of the request body
│   │   ├── NotionError.swift                   # typed errors (auth, db-not-found, http, network)
│   │   └── NotionValidation.swift              # pure: validateConfig(...) → NotionConfigStatus
│   │
│   ├── Settings/
│   │   └── NotionSection.swift                 # NEW — section in the Settings tab UI
│   │
│   ├── Pipeline/
│   │   └── ProcessingPipeline.swift            # extend: fire NotionMeetingWriter after a successful
│   │                                            #         organize() — never blocks the success path
│   │
│   └── AuditLog/
│       └── AuditLogEntry.swift                 # extend: + notionStatus (.skipped, .succeeded(url), .failed)
│                                                #         — schemaVersion bump
```

### Notes

- **`NotionMeetingWriter` is a protocol** so the pipeline can be tested with a fake. The concrete `NotionClient` is the only thing that talks to the network.
- **`NotionPageBuilder` is pure** — given a meeting name, transcript text, and compiled context, it returns the exact JSON payload Notion expects (parent database + properties + children blocks). Tested exhaustively without touching the network.
- **No new sidebar tab.** Per PRD §4.1 the Notion controls live under Settings — they're configuration, not their own surface.

---

## 1. Phase A — Settings model + secret storage

**Goal:** The data the rest of the feature reads — the toggle, the database ID, the token — is persisted correctly. No UI yet, no network.

1. **Extend `AppSettings`** (`Core/Settings/AppSettings.swift`):
   - `notionEnabled: Bool` (UserDefaults, default `false`).
   - `notionDatabaseId: String` (UserDefaults, default `""`).
   - `notionToken: String?` — Keychain-backed, mirroring the existing `apiKey` pattern. Account `"notion_token"`, same service as `apiKey` so Debug/Release stay separated by bundle ID.
2. **Centralize the Keychain account names.** The existing `static let apiKeyAccount = "api_key"` becomes a pair: add `static let notionTokenAccount = "notion_token"`. Don't reuse the same account.
3. **`NotionConfig.swift`** — non-persisted struct that the pipeline / writer take as input: `token: String`, `databaseId: String`, `apiVersion: String = "2022-06-28"` (Notion's stable API version header). Built from `AppSettings` at pipeline start, mirroring how `PipelineConfig` snapshots the settings it needs.
4. **`NotionValidation.swift`** — pure: `validate(_ settings: AppSettings) -> NotionConfigStatus`. Returns one of:
   - `.disabled` (toggle off).
   - `.misconfigured(reason: String)` (toggle on, but token empty / databaseId empty / databaseId malformed).
   - `.ready(NotionConfig)` (toggle on + token + databaseId present).
5. **Tests** (`JotTests/Core/Settings/` and `JotTests/Features/Notion/`):
   - Unit: `AppSettingsNotionTests` — UserDefaults round-trip for toggle + databaseId; Keychain stub round-trip for token; clearing the token deletes the Keychain entry (mirror existing `apiKey` tests).
   - Unit: `NotionValidationTests` — all four status branches; whitespace-only token treated as empty; malformed-databaseId rule decided here (recommend: must be a 32-char hex string, optionally hyphenated, otherwise `.misconfigured`).
   - Integration: not needed at this phase — no I/O beyond UserDefaults and the in-memory Keychain fake.

**Deliverable:** Settings persist correctly across "relaunches" (tests). `NotionValidation.validate(...)` returns the right status for every state. No network, no UI.

---

## 2. Phase B — Notion client + page builder

**Goal:** Given a `NotionConfig` and the three pieces of meeting data, post a request to Notion's `/v1/pages` endpoint that creates a page with exactly the three toggle sections. Fully testable against `URLProtocol`, never touches the live API in CI.

1. **`NotionPagePayload.swift`** — `Encodable` shape of the request body Notion's [Create a page](https://developers.notion.com/reference/post-page) endpoint expects:
   - `parent: { database_id: <id> }`.
   - `properties`: just the database's title property, set to the meeting name. Notion requires the *exact* title property key — we look it up at runtime from the database schema (see step 4) and cache it on `NotionClient`.
   - `children: [Block]` — three `toggle` blocks, in order: "Meeting Notes" (empty children), "Meeting Transcript" (children = paragraph blocks containing transcript text), "Additional Context" (children = paragraph blocks containing compiled context).
2. **Paragraph chunking.** Notion's API caps a single `rich_text` array at 100 entries and each text entry at 2000 characters. `NotionPageBuilder` splits transcript / context into paragraph blocks of ≤2000 chars on word boundaries, and groups them into multiple paragraph children if needed. Toggle blocks themselves cap their `children` array at 100 blocks per request — for transcripts that exceed ~200KB of text we fall back to issuing a follow-up `PATCH /v1/blocks/<toggle_id>/children` call to append the remainder. Phase D wires this fallback in.
3. **`NotionPageBuilder.build(meetingName:, transcript:, additionalContext:) -> NotionPagePayload`** — pure. No I/O. Empty `additionalContext` still produces the "Additional Context" toggle (PRD §4.3 mandates exactly three sections); we just give it a single empty paragraph child so Notion accepts it.
4. **`NotionClient.swift`** — concrete `NotionMeetingWriter` impl. Two methods used externally:
   - `func createMeetingPage(config: NotionConfig, meetingName: String, transcript: String, additionalContext: String) async throws -> NotionPageResult` — orchestrates: look up the database's title-property key (cached), build payload, POST `/v1/pages`, if response was truncated (see step 2) issue follow-up appends, return the new page URL.
   - `func describeDatabase(config: NotionConfig) async throws -> NotionDatabaseInfo` — `GET /v1/databases/<id>`, used for the validation handshake in Phase C and to resolve the title-property key. Cache the result keyed by `databaseId` so we don't refetch on every meeting.
5. **Networking shape.** Use `URLSession.shared` with explicit `Authorization: Bearer <token>` and `Notion-Version: <apiVersion>` headers. Timeouts: 10s for `describeDatabase`, 60s for `createMeetingPage` (large transcripts in the body). Cancel in-flight tasks on app quit (mirror `TranscriptionClient`).
6. **`NotionError.swift`** — typed enum: `.unauthorized` (401), `.databaseNotFound` (404), `.rateLimited(retryAfter: TimeInterval?)` (429), `.invalidRequest(message:)` (4xx with parseable body), `.serverError(status: Int)` (5xx), `.transport(URLError)`, `.decoding(Error)`. Each case has a `userFacingMessage: String` mirroring `TranscriptionError`.
7. **Retry policy.** Per PRD §6 "Keep retry behavior minimal and explicit; avoid complex backoff orchestration in this phase." Implementation: **no retries**. A failure is logged + surfaced to the audit log and that's the end of it. The user can manually re-run the meeting later if we ever add that affordance (currently out of scope).
8. **Tests** (`JotTests/Features/Notion/`):
   - Unit: `NotionPageBuilderTests` — exhaustive: three blocks present in correct order; toggle titles match PRD exactly ("Meeting Notes", "Meeting Transcript", "Additional Context"); transcript split across paragraph blocks at correct boundaries; empty context still produces the third toggle; meeting-name → title-property mapping uses the resolved key.
   - Unit: `NotionErrorMappingTests` — every HTTP status maps to the correct `NotionError` case; transport errors wrap `URLError`; decoding failures don't escape as raw `DecodingError`.
   - Integration: `NotionClientIntegrationTests` — `URLProtocol` mock; happy path (POST /v1/pages with the exact expected JSON body, server returns 200 with a page URL, client returns it); 401 → `.unauthorized`; 404 → `.databaseNotFound`; rate-limit honors `Retry-After`; large transcript triggers follow-up append calls in the right order.

**Deliverable:** Hand `NotionClient` a config + three strings, it produces an HTTP POST whose body has exactly the three toggle sections in exactly the PRD order, with sane behavior on every HTTP failure mode. Tested without touching api.notion.com.

---

## 3. Phase C — Settings UI

**Goal:** The user can flip the Notion toggle on, paste a token, paste a database ID, and see a clear "Connected to <database name>" or "Misconfigured: <reason>" status. No live ping until the user clicks a "Test connection" button — we don't want every Settings open to hit Notion.

1. **`Features/Settings/NotionSection.swift`** — new section, slotted into the existing Settings tab below the API/Folders sections. Follows the same `SettingsLayout` patterns as the other sections.
2. **Controls.**
   - "Enable Notion meeting creation" — `Toggle` bound to `AppSettings.notionEnabled`. When OFF, the rest of the section is dimmed but visible (PRD §4.1).
   - "Notion integration token" — `SecureField` bound to `AppSettings.notionToken`. Helper text: a one-liner explaining the user must create an internal Notion integration and share the target database with it (link to Notion's docs page, not a URL we invent — open the user's browser via `NSWorkspace.shared.open(_:)`).
   - "Target database ID" — `TextField` bound to `AppSettings.notionDatabaseId`. Helper text on how to get it (copy from the database's URL, the 32-char ID segment).
   - "Test connection" button — runs `NotionClient.describeDatabase(...)` against the current config. On success, replaces the button's adjacent label with `"Connected · <database name>"`. On failure, shows `NotionError.userFacingMessage` in red.
3. **Live validation indicator.** Below the controls, a one-line status driven by `NotionValidation.validate(settings)`:
   - `.disabled` — `"Disabled"` in secondary text color.
   - `.misconfigured(reason)` — `"Setup needed: \(reason)"` in warning color.
   - `.ready` — `"Ready"` in success color (no implication the credentials are correct — that's what Test connection is for).
4. **No background polling, no auto-test.** The Test connection button is the only thing that hits the network from the Settings tab. Keeps the settings open/close path zero-cost.
5. **Logging.** `Log.notion.info` (new category in `Core/Logging/Log.swift`) for every meaningful action: "Notion enabled", "Notion disabled", "Test connection succeeded", "Test connection failed: \(error.userFacingMessage)". Never log the token — same rule as `apiKey` (`coding-instructions.md` §3).
6. **Tests** (`JotTests/Features/Settings/`):
   - Unit: `NotionSectionViewModelTests` (if a view-model is introduced — recommended for the test-connection action so we don't hit the network from a SwiftUI body) — happy path, each error path, status string for each `NotionConfigStatus` case.
   - Integration: not at the UI layer (per `coding-instructions.md` §6, SwiftUI views aren't snapshot-tested in this project).

**Deliverable:** Open Settings → see Notion section → enable, paste token + ID → click Test → green "Connected · MyDatabase" appears. Quit and relaunch — toggle, ID, and token all persist; token came from Keychain.

---

## 4. Phase D — Pipeline integration (post-success hook)

**Goal:** When `ProcessingPipeline.process(url:)` reaches the "success" path — transcript filed, audio moved, audit entry about to be written — fire the Notion writer with the three pieces of data. The success audit entry is enriched with the Notion outcome; the pipeline returns to idle without waiting for the Notion call to complete.

1. **`NotionMeetingWriter` protocol** (declared in Phase B). Re-stated here because this is the seam:
   ```swift
   protocol NotionMeetingWriter: Sendable {
       func createMeetingPage(
           config: NotionConfig,
           meetingName: String,
           transcript: String,
           additionalContext: String
       ) async throws -> NotionPageResult
   }
   ```
2. **Wire into `ProcessingPipeline`.** Mirror the existing `consumeMeetingContext` callback pattern: inject a closure `notionWrite: (@Sendable (NotionWriteRequest) async -> NotionWriteOutcome)?` that the pipeline calls on success. The closure is built by `PipelineCoordinator` against the current `AppSettings` snapshot — if Notion is disabled/misconfigured, the coordinator passes `nil` and the pipeline does nothing.
3. **Inputs to the Notion write.** From the in-pipeline context (which already exists today):
   - `meetingName` — from `snapshot.meetingName` (after rename), or the original filename if no snapshot.
   - `transcript` — the string we just wrote to disk.
   - `additionalContext` — `snapshot?.resolvedCompiledContext ?? ""`. Empty when there was no org / no meeting-specific context.
4. **Fire-and-forget, but tracked.** The pipeline `await`s the Notion call but inside a `Task { ... }` *after* it has already called `onAuditEntry(.success(...))` and `onStateChange(.idle)` with a `notionStatus: .pending` field. When the task completes (success or failure), it issues a second audit entry of kind `.info` (`"Notion: page created → <url>"`) or `.failure`-but-non-blocking (`"Notion: write failed — <message>"`). The success row in the UI is then either updated in place or the second row sits next to it — pick during impl (recommend update-in-place via the audit log's existing entry-id matching).
5. **Cancellation.** If the pipeline shuts down (app quit, settings change) before the Notion task completes, the task is cancelled. A cancelled Notion write does **not** produce an audit entry — silent drop is correct, the meeting itself was logged as a success already.
6. **Skip path.** When `notionWrite` is `nil` (disabled or misconfigured), the success audit entry has `notionStatus = .skipped`. No extra log noise.
7. **Tests** (`JotTests/Features/Pipeline/`):
   - Unit: `ProcessingPipelineNotionTests` — fake `NotionMeetingWriter`; assert it's called with the exact `meetingName`, `transcript`, `additionalContext` after a successful organize; assert it's *not* called if `notionWrite` is nil; assert the audit log gets the right pair of entries on success / write-failure.
   - Integration: `PipelineNotionIntegrationTests` — full pipeline with the `URLProtocol`-mocked `NotionClient`. Drop a file → assert transcript on disk, assert second audit entry within N seconds. Drop a file with the Notion mock returning 401 → assert transcript on disk *and* `notionStatus = .failed` on the row.

**Deliverable:** Drop a real-looking mp3 with the Notion settings configured (against the URLProtocol mock) → pipeline writes the transcript + context.md + audio → the Notion task fires in the background → audit log row ends up with `Notion: page created → <url>`. With Notion disabled, behavior is byte-identical to v0.2.x.

---

## 5. Phase E — Audit log surface

**Goal:** The user can see, per meeting, whether a Notion page was created — and if not, why.

1. **`AuditLogEntry.swift`** — add `notionStatus: NotionStatus?` (nil for older entries; explicit value on entries written by this version). `NotionStatus` is a sibling Codable enum:
   - `.skipped(reason: SkipReason)` where `SkipReason ∈ { .disabled, .misconfigured }`.
   - `.pending` — set the moment the success entry is written; replaced when the task completes.
   - `.succeeded(pageURL: URL)`.
   - `.failed(message: String)`.
2. **Schema bump.** `AuditLogEntry.schemaVersion` goes from 2 → 3. Decoder for v2 entries supplies `notionStatus = nil`. Migration is one-way per `development-lifecycle.md` §6.
3. **`AuditLogRow.swift`** — extend the success row's subtitle:
   - `.skipped(.disabled)` — no extra text (the default user; don't nag).
   - `.skipped(.misconfigured)` — `· Notion: setup needed`.
   - `.pending` — `· Notion: …` with a spinner glyph.
   - `.succeeded(url)` — `· Notion: page created` rendered as a link that opens `url` in the browser.
   - `.failed(message)` — `· Notion: failed` with the message in a tooltip / detail disclosure.
4. **In-place mutation.** When the Notion task finishes, the pipeline updates the audit log entry whose id matches the just-completed meeting. `AuditLogStore` already exposes an entry-id; if it doesn't expose an `update(id:_:)` method, add it as part of this phase.
5. **Tests** (`JotTests/Features/AuditLog/`):
   - Unit: `AuditLogEntryTests` — schema-2 → schema-3 round-trip (v2 file on disk loads with `notionStatus = nil`); v3 → v3 round-trip for every `NotionStatus` case.
   - Integration: `AuditLogPersistenceIntegrationTests` — drop a schema-2 file on disk, load store, verify it migrates and re-saves as schema 3 on first write.

**Deliverable:** Process a meeting → audit log row shows "Notion: page created → <link>". Click the link → browser opens the new Notion page.

---

## 6. Phase F — Release + tighten

**Goal:** Ship the feature behind a single demoable release.

1. **Cross-phase smoke test.** `JotTests/Features/Notion/EndToEndIntegrationTests.swift` — enable Notion in `AppSettings`, configure a `NotionConfig`, drop a file through a full `ProcessingPipeline` with `URLProtocol`-mocked Notion; assert: transcript on disk, context.md on disk, audit log row has `.succeeded(url)`, the exact JSON body that hit Notion contains the three toggle sections in the right order with the right content.
2. **Backwards-compat smoke test.** `LegacyNotionDisabledFlowTests` — same pipeline, Notion toggle OFF; assert: zero outgoing Notion requests, audit row has `notionStatus = .skipped(.disabled)`. v0.2.x users who never touch the new settings see no behavioral change.
3. **Failure-mode smoke tests.** Re-runs of the above with the Notion mock returning 401, 404, 429, 500. Each one asserts: the transcript / context.md / audio move all succeeded, only the Notion side changed.
4. **Manual one-time live check.** Per `coding-instructions.md` §8 "Verify, don't assert": create a real Notion internal integration, share a real test database, run one real meeting end-to-end with the Release build, confirm the page lands and has exactly the three toggles. Document the steps in `scripts/notion-smoke-check.md` (not a public doc — a runbook for the next release).
5. **CHANGELOG.** New entry `v0.3.0 — Notion meeting creation`. Highlight: optional toggle, three predefined sections, never blocks core pipeline.
6. **Versioning.** Minor bump — additive feature under 1.x (per `development-lifecycle.md` §5.1, MINOR for new features). Tag `v0.3.0`.
7. **Verification before tag.** Build Release, install over the running v0.2.x via Sparkle's local-install path (or drag-replace), walk the happy path once on a real meeting, confirm the new Notion page + the audit log link + that toggling Notion off restores v0.2.x behavior.

**Deliverable:** `v0.3.0` reaches the user's Mac via Sparkle. With Notion configured, every transcript lands as a new database page; with Notion off, nothing changes from v0.2.x.

---

## Out of scope (per PRD §3 + §9 + implementation triage)

- AI summarization or action-item extraction (PRD §3, §9).
- Bi-directional sync from Notion back into Jot (PRD §9).
- Rich templating beyond the three required toggles (PRD §9).
- Auto-fill of the Meeting Notes section (PRD §3 — explicit non-goal).
- Retry / backoff orchestration beyond a single attempt (PRD §6 — "Keep retry behavior minimal and explicit").
- A "manual re-send to Notion" affordance from the audit log. Worth considering for v0.3.1 if real-world misses happen, but not v0.3.0.
- Configurable section names. PRD §4.3 fixes them as "Meeting Notes", "Meeting Transcript", "Additional Context" — we ship those literals.
- Real MCP protocol support — see §0.5 above. The user-facing Settings label can keep the word "Notion" without committing to MCP under the hood.
- Bulk export of past meetings into Notion. v0.3.0 only acts on meetings processed *after* the toggle goes on.

---

## Phase → release mapping

| Phase | Deliverable | Branch | Tag |
|---|---|---|---|
| A | Settings model + Keychain entry for token | `feat/notion-settings-model` | — |
| B | NotionClient + page builder + URLProtocol tests | `feat/notion-client` | — |
| C | Settings UI (toggle, token, db ID, test button) | `feat/notion-settings-ui` | — |
| D | Pipeline post-success hook + audit-log enrichment | `feat/notion-pipeline-hook` | — |
| E | Audit log row UI for `notionStatus` | `feat/notion-audit-row` | — |
| F | E2E test + release prep | `release/v0.3.0` | `v0.3.0` |

Each phase is its own PR, reviewed and merged into `main` before the next starts. No phase is shippable on its own — observable behavior is gated behind Phase D (pipeline wiring). Tag only after Phase F verification.

---

## Open questions (resolve during Phase A kickoff)

1. **Literal MCP vs Notion REST.** §0.5 recommends REST via `URLSession`. Confirm. If the user genuinely wants MCP, the plan needs a transport-shim phase between B and C and the dependency / sandbox story changes.
2. **Database-ID format validation.** Recommend "32 hex chars, optionally hyphenated" (Phase A.4). Anything stricter pushes the validation cost onto the user; anything looser lets a typo through to Notion. Confirm during impl.
3. **Audit-row update-in-place vs second row.** Recommend update-in-place (Phase D.4) so the user sees one row per meeting. If `AuditLogStore` doesn't already support mutate-by-id, that's a small additive change inside Phase D.
4. **Token rotation / connection-status sentinel.** Today the only verification of the token is the "Test connection" button. If we want a passive `lastSuccessfulNotionCallAt` indicator in Settings, that's a half-day add — defer to v0.3.1 unless the user wants it in v0.3.0.
5. **Pre-1.0 versioning.** v0.2.x is currently shipping (Add Context); the next minor (`v0.3.0`) is the right home for this. Per `development-lifecycle.md` §5.1 the milestone-to-MINOR mapping originally pinned `0.3.0` to "M3 = full main window with Audit Log + Transcripts tabs". Both are shipped now, so the mapping is loose — using `v0.3.0` for Notion is fine. Confirm during Phase F.
