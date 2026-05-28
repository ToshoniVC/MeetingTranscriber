# Jot — Implementation Plan: Add Context

Derived from [`../PRD/AddContext_PRD_2026_05_28.md`](../PRD/AddContext_PRD_2026_05_28.md). This plan **extends the shipped v0.1.x app** (built per the archived [v2026_05_27 plan](archive/implementation-plan_v2026_05_27.md)) with a new **Context** tab: per-organization profiles plus per-meeting context that flow into the transcription request as the OpenAI Whisper `prompt` parameter and into the output folder as a `context.md` artifact.

> The PRD calls the tab "Custom Context"; we render it as just "Context" in the sidebar (user direction, 2026-05-28). Internal identifiers use `context` to match.

---

## 0. Guiding constraints (from the PRD + standing rules)

- **Additive only.** Existing transcription-only workflows must keep working when no context is provided (PRD §11.9). Don't break the no-org path.
- **Feature-Driven Design.** Two new feature folders: `Features/Organizations/` and `Features/MeetingContext/`. Cross-feature reach-ins are not allowed (per `coding-instructions.md` §2). The Pipeline calls into `MeetingContext` via a small public surface, not the other way around.
- **Local-only storage.** Organization profiles and meeting context live on disk in `~/Library/Application Support/Jot/`. No cloud sync (PRD §3, §10).
- **Secrets unchanged.** API key stays in Keychain. Context payload must never include API keys (PRD §6, §10).
- **Whisper `prompt` is the carrier.** OpenAI-compatible `/audio/transcriptions` endpoints accept a `prompt` form field (up to 224 tokens). We compile context into that field. Non-supporting endpoints ignore unknown fields — graceful degradation is the default, no opt-out needed in v1 (PRD §7).
- **Schema migrations.** New persisted models carry `schemaVersion: Int` per `development-lifecycle.md` §6.
- **Tests in the same PR as the feature.** Unit + integration per `coding-instructions.md` §6.

---

## 0.5 Folder additions

```
Jot/
├── Core/
│   └── App/
│       └── MainWindow.swift                # extend MainTab enum: + .context
│
└── Features/
    ├── Organizations/                       # NEW — Tab 4: Context
    │   ├── OrganizationsView.swift          # list/detail split (sidebar of orgs + editor)
    │   ├── OrganizationsListView.swift      # left pane: rows + add/delete
    │   ├── OrganizationDetailView.swift     # right pane: editable fields
    │   ├── Organization.swift               # Codable struct (schemaVersion: 1)
    │   ├── AcronymEntry.swift               # term + expansion (nested Codable)
    │   ├── OrganizationStore.swift          # actor; organizations.json persistence
    │   └── OrganizationValidation.swift     # unique name, single default, etc.
    │
    ├── MeetingContext/                      # NEW — context compilation + per-meeting snapshot
    │   ├── MeetingContextSnapshot.swift     # Codable; meetingName, orgId, freeText, compiled
    │   ├── MeetingContextStore.swift        # @Observable; in-memory current snapshot,
    │   │                                    # consumed at file-arrival time (like MeetingNameStore)
    │   ├── ContextCompiler.swift            # deterministic ordering + dedupe + budget
    │   └── ContextCompilerBudget.swift      # token-budget constants & truncation strategy
    │
    ├── Pipeline/
    │   ├── MeetingNameStore.swift           # extend or fold into MeetingContextStore (see Phase D)
    │   └── FileOrganizer.swift              # extend: also write context.md when non-empty
    │
    ├── Transcription/
    │   ├── TranscriptionClient.swift        # extend signature: + prompt: String?
    │   └── TranscriptionRequest.swift       # add `prompt` multipart field when present
    │
    ├── AudioHijack/
    │   └── SystemMeetingNamePrompter.swift  # extend or replace: prompt for org + optional context
    │
    └── AuditLog/
        └── AuditLogEntry.swift              # add: contextAttached, organizationName (schemaVersion bump)
```

### Notes

- **`MeetingContext/` is headless** (no view of its own); its UI surfaces are the meeting-start prompt (in `AudioHijack/`) and the in-recording editor (new — see Phase E). The model + compiler are the feature; the views consume them.
- **`MeetingNameStore` vs new `MeetingContextStore`.** The store today tracks only the meeting name. The Add Context work needs the same lifecycle (set at start, consumed at file arrival, cleared on relaunch) for org + meeting-specific context too. Phase D decides whether to extend the existing store or wrap it in a richer `MeetingContextStore` — see that phase for the trade-off.
- **The Context tab is the 4th sidebar item.** `MainTab.allCases` drives the sidebar in `MainWindow.swift`, so adding the enum case is sufficient for it to appear.

---

## 1. Phase A — Organizations data model + persistence

**Goal:** A round-tripped, validated organization store on disk that the rest of the feature can build against. No UI yet.

1. **`Features/Organizations/Organization.swift`** — `Codable` struct matching PRD §5.1: `id: UUID`, `name: String`, `companyName: String?`, `staffNames: [String]`, `projectNames: [String]`, `glossaryTerms: [String]`, `acronyms: [AcronymEntry]`, `freeformNotes: String?`, `isDefault: Bool`, `createdAt: Date`, `updatedAt: Date`. Add `schemaVersion: Int = 1` (per `development-lifecycle.md` §6).
2. **`AcronymEntry.swift`** — `Codable` struct: `term: String`, `expansion: String`.
3. **`OrganizationStore.swift`** — `@MainActor @Observable` class wrapping disk persistence at `~/Library/Application Support/Jot/organizations.json`. API: `all() -> [Organization]`, `upsert(_:)`, `delete(id:)`, `setDefault(id:)`, `defaultOrg() -> Organization?`. Persists on every mutation. Mirror the patterns in `AuditLogStore` and `ProcessedFilesLedger`.
4. **`OrganizationValidation.swift`** — pure functions: `validateName(_:, against: [Organization]) throws -> Void` (non-empty, unique case-insensitive within the store), `enforceSingleDefault(after: Organization, in: [Organization]) -> [Organization]` (clears `isDefault` on others when one is being set). Validation errors are a typed `OrganizationValidationError` enum.
5. **No migration code yet** — `schemaVersion = 1` is the first shipped version; the decoder dispatches on version but only has the v1 branch.
6. **Tests** (`JotTests/Features/Organizations/`):
   - Unit: `OrganizationValidationTests` (empty/duplicate names, single-default enforcement, edge cases like trimming/casing). `OrganizationTests` (Codable round-trip with all-optional fields nil; with all fields populated).
   - Integration: `OrganizationStoreIntegrationTests` — real tmpdir, real `FileManager`; insert → restart store from disk → verify all fields and `isDefault` round-trip. Verify two stores pointed at the same file see each other's writes on reload.

**Deliverable:** Org CRUD works programmatically, persisted across "relaunches" (tests), validation rules enforced. No UI yet.

---

## 2. Phase B — Context tab (UI)

**Goal:** The 4th sidebar tab with full CRUD for organizations.

1. **Extend `MainTab` enum** in `Core/App/MainWindow.swift` with `.context` (title "Context", systemImage e.g. `"person.text.rectangle"`). Wire the `switch` in `detail:` to route to `OrganizationsView()`.
2. **`Features/Organizations/OrganizationsView.swift`** — root view. `HSplitView` (or `NavigationSplitView` nested under the main one — pick whichever the existing app style favors) with the org list on the left, the detail editor on the right.
3. **`OrganizationsListView.swift`** — `List` of org names, badge for the default org. Bottom toolbar: `+` to add (creates a new org with a placeholder name, immediately editable), `-` to delete (with confirm dialog). The system-provided "No Organization" entry is shown at the top, pinned, non-deletable, non-editable (it's a UI affordance, not a stored record).
4. **`OrganizationDetailView.swift`** — form for editing the selected org's fields. Sections:
   - Identity: name (required), company.
   - Lists: staff, projects, glossary terms — each a `List` with add/remove buttons and inline-edit rows.
   - Acronyms: paired `term`/`expansion` rows.
   - Notes: multiline `TextEditor`.
   - Default toggle: `Toggle("Default for new meetings", isOn: ...)`. Toggling it on clears the flag on whichever org currently holds it.
5. **Validation surfacing.** Inline error under the name field on duplicate / empty; disable save / autosave-with-rollback (pick one — autosave with revert on error is the more SwiftUI-native pattern).
6. **No selection state.** If the user has no orgs yet, show an empty-state with a "Create your first organization" call to action.
7. **Tests** (`JotTests/Features/Organizations/`):
   - Unit: `OrganizationsListViewModelTests` (if a view-model is introduced) — sorting (default first, then alphabetical), insertion, deletion, selection follow-through.
   - Integration: none required at the UI layer beyond what Phase A already covers. SwiftUI view tests are intentionally not part of our testing posture (`coding-instructions.md` §6 lists logic and integration, not UI snapshots).

**Deliverable:** Open the main window → click "Context" → see the new tab → create, edit, delete orgs, set a default → quit and relaunch → everything restored.

---

## 3. Phase C — Meeting context compilation

**Goal:** The pure-function engine that turns `(Organization?, meetingName, meetingSpecificContext?)` into the compiled `prompt` string.

1. **`Features/MeetingContext/MeetingContextSnapshot.swift`** — `Codable` struct (schemaVersion: 1) capturing PRD §5.2: `meetingName: String`, `organizationId: UUID?`, `meetingSpecificContext: String?`, `resolvedCompiledContext: String`, `lastEditedAt: Date`. The snapshot is what gets written to `context.md` (Phase G) and what the audit log references (Phase G).
2. **`ContextCompiler.swift`** — `static func compile(meetingName: String, meetingContext: String?, organization: Organization?, budget: ContextCompilerBudget = .default) -> String`. Ordering per PRD §6:
   1. System prefix (one line: `"Context for transcription accuracy:"` or similar — chosen during impl).
   2. Organization name / company.
   3. Staff names.
   4. Project names.
   5. Glossary + acronyms (acronyms rendered as `TERM = expansion`).
   6. Organization freeform notes.
   7. Meeting name.
   8. Meeting-specific context.
3. **Trim + dedupe rules.** Per PRD §6: trim whitespace on each entry; dedupe case-insensitive across the same list; never dedupe across different sections (a staff name that happens to equal a project name appears in both).
4. **`ContextCompilerBudget.swift`** — defines `maxCharacters: Int = 800` (the Whisper `prompt` field is hard-capped at 224 tokens server-side; 800 chars is ~200 tokens for typical English with headroom for acronym-heavy content that tokenizes at ~1–2 chars/token — exactly the kind of content this feature exists to send). Exposed as a constant so it's tunable later if a provider supports a larger window. Truncation strategy when the compiled string exceeds `maxCharacters`: drop sections from the bottom up in PRD §6 order (meeting-specific context first, then meeting name, then org freeform notes, then glossary/acronyms, …) — i.e., the *least-important* sections go first; the org identity (name, company) is never truncated. Document the strategy in the file header.
5. **Empty-context path.** If org is nil and meeting-specific context is empty / whitespace-only, return `""`. Callers downstream interpret empty as "send no `prompt` field at all" (Phase F).
6. **`MeetingContextStore.swift`** — `@MainActor @Observable` class. **Decision: extend rather than replace `MeetingNameStore`.** The store holds the in-flight `MeetingContextSnapshot` for the *currently active* recording (mirroring `MeetingNameStore.pending`). API: `recordStarted(name:, organizationId:, meetingContext:)`, `update(name:, organizationId:, meetingContext:)` (called by the in-recording editor — Phase E), `consume(forFileCreatedAt:) -> MeetingContextSnapshot?`. Internally either wraps `MeetingNameStore` or replaces it — pick during impl, the API surface matters more than the internals.
7. **Tests** (`JotTests/Features/MeetingContext/`):
   - Unit: `ContextCompilerTests` — exhaustive: ordering across each PRD-§6 section, trim/dedupe, empty inputs (nil org + nil meeting context returns `""`), budget truncation (verify which sections survive at each shrink step), unicode/non-ASCII safety. `MeetingContextSnapshotTests` — Codable round-trip.
   - Integration: not needed for this phase — the compiler is pure logic. Cross-phase integration lands in Phase F's pipeline test.

**Deliverable:** A pure compile function with high test coverage that produces a deterministic `prompt` string. The in-memory store has the right shape to feed Phase F.

---

## 4. Phase D — Meeting start flow

**Goal:** The user can't start a meeting without selecting an organization (or explicit "No Organization"), and can optionally add meeting-specific context up front. Default org pre-selected.

1. **Extend `SystemMeetingNamePrompter`** (in `Features/AudioHijack/`) into something like `SystemMeetingStartPrompter`. Inputs to the prompt: meeting name (required), organization picker (required — populated from `OrganizationStore.all()` plus the "No Organization" sentinel, default org pre-selected), meeting-specific context (optional multiline). Output: a `MeetingStartInputs` struct passed back to the caller.
2. **Validation in the prompter.** Disable the "Start" button until name is non-empty and org is selected (the default org being pre-selected satisfies this on first open). "No Organization" is a valid selection.
3. **Wire into `HotkeyCoordinator` / `AudioHijackController`.** The existing call site that produces a meeting name now produces a `MeetingStartInputs`. That gets fed to `MeetingContextStore.recordStarted(...)` (which supersedes `MeetingNameStore.recordStarted(name:)`).
4. **No-orgs-yet edge case.** If the org store is empty, the picker shows only "No Organization" (no broken state). The user can still record; they're nudged via a one-time inline hint pointing at the Context tab.
5. **Backwards compatibility.** A user who has no orgs and never opens the new tab still sees the recording flow work — just with an extra picker that defaults to "No Organization".
6. **Tests** (`JotTests/Features/AudioHijack/` and `JotTests/Features/Pipeline/`):
   - Unit: `MeetingStartPrompterTests` — validation rules (name required, org required, default pre-selected, empty-store falls back to No Organization). `MeetingContextStoreTests` — extends the existing `MeetingNameStoreTests` patterns with org + context fields.
   - Integration: `MeetingStartFlowIntegrationTests` — fake prompter; trigger hotkey → assert `MeetingContextStore.pending` matches the prompter's output. Cover the default-org case, the no-orgs case, and the user-overrides-default case.

**Deliverable:** Press the recording hotkey → see the upgraded prompt with org picker and optional context box → start recording → `MeetingContextStore` holds the right snapshot.

---

## 5. Phase E — In-recording metadata editing

**Goal:** While a recording is active, the user can open a "Current Meeting" surface and edit name / org / meeting-specific context. Edits apply to the snapshot that will be compiled when the file arrives.

1. **Menu-bar surface only.** A new "Edit current meeting…" entry in the menu-bar dropdown, visible only while `menuBar.isRecording == true`. Clicking it opens a small floating window (`Window` scene with `id: "current-meeting-editor"` so it can be opened/closed independently of the main window — the main window may not be open at all during a recording). No equivalent affordance in the main window in v1.
2. **`Features/MeetingContext/CurrentMeetingEditorView.swift`** — three fields (name, org picker, meeting-specific context) bound to `MeetingContextStore.pending`. Save commits via `MeetingContextStore.update(...)` which stamps `lastEditedAt`. Cancel closes without writing. Window auto-closes if `pending` becomes nil (i.e., the file arrived and was consumed while the editor was open — see step 4).
3. **Read-after-stop safety.** Edits applied after `recordStopped(at:)` but before `consume(forFileCreatedAt:)` are still respected — the compile step happens at file arrival, not at stop. Document this in the store's header.
4. **Race with file arrival.** If the user is mid-edit when the file lands and `consume` fires, we take the snapshot as it stood at consume time (last write wins; the editor's pending edits are dropped). Acceptable for v1 — locking the editor while the pipeline runs would be more code than the edge case deserves. Document the behavior in `CurrentMeetingEditorView`.
5. **Tests** (`JotTests/Features/MeetingContext/`):
   - Unit: `MeetingContextStoreUpdateTests` — `update(...)` after start changes the snapshot the next `consume` returns; `update(...)` after `consume` is a no-op (pending is already nil).
   - Integration: `CurrentMeetingEditingIntegrationTests` — start → edit name/org/context → consume → assert returned snapshot reflects edits.

**Deliverable:** Recording in flight → open the editor → change the org and add a note → stop recording → file lands → the compiled context reflects the edits.

---

## 6. Phase F — Pipeline + API context integration

**Goal:** The compiled context actually reaches the transcription endpoint.

1. **`TranscriptionRequest.swift`** — add an optional `prompt: String?` parameter. When non-nil and non-empty, append a `prompt` multipart form field. When nil/empty, omit the field entirely (matches the existing OpenAI behavior — endpoints that don't support `prompt` ignore unknown fields, so the absence is the safe default).
2. **`TranscriptionClient.transcribe(...)`** signature extension: `transcribe(audio:baseURL:model:apiKey:prompt:)`. Existing callers pass `prompt: nil` until Phase F wiring is complete — keeps Phase A–E changes safely behind the new field.
3. **`ProcessingPipeline.swift` (actor)** — when a file lands and we have a `MeetingContextSnapshot` from `MeetingContextStore.consume(...)`:
   - Call `ContextCompiler.compile(...)` to produce the `prompt` string (will already be in `snapshot.resolvedCompiledContext` if Phase E populated it; recompile here defensively to handle org-data-changed-after-record edge cases).
   - Pass the result through to `TranscriptionClient.transcribe(prompt:)`.
   - Stash the compiled string for Phase G (output artifact + audit log).
4. **Empty-context safety.** If `compile(...)` returns `""`, pass `nil` to the client. This is the path that today's pre-Add-Context users will take — no behavioral change for them.
5. **Endpoint compatibility logging.** Per PRD §7: log via `os.Logger` (`pipeline` or new `context` category) whether the prompt was included. Provider-capability handshake / config flag is out of scope for v1 — graceful-by-omission is sufficient.
6. **Tests** (`JotTests/Features/Transcription/` and `JotTests/Features/Pipeline/`):
   - Unit: `TranscriptionRequestTests` (existing) — extend with cases: prompt nil → no field; prompt set → field present with exact value; prompt with newlines round-trips. `TranscriptionErrorMappingTests` — unchanged.
   - Integration: `PipelineIntegrationTests` (existing) — extend with: org configured → file lands → `URLProtocol` mock receives multipart body containing `prompt` field with compiled value. No-org case: mock receives body with no `prompt` field. Bad-org case (org references deleted mid-recording): falls back to whatever org-less context produces.

**Deliverable:** Drop a file with an active org snapshot → multipart upload includes the compiled `prompt` → endpoint receives it → transcript comes back. Drop a file with no org snapshot → behaviour identical to today.

---

## 7. Phase G — Output artifact + audit log

**Goal:** The compiled context is preserved on disk next to the audio + transcript, and the audit log shows whether context was attached and which org was used.

1. **`FileOrganizer.swift`** — extend `organize(audio:transcript:outputRoot:)` to `organize(audio:transcript:context:outputRoot:)` where `context: String?`. When non-nil and non-empty, write `<meetingName>-context.md` (or `context.md` — see naming decision below) into the meeting folder alongside the transcript. Markdown body wraps the compiled context in a fenced block plus a one-line header (`# Transcription context (sent with audio)`).
   - **Naming decision.** PRD §8 suggests `context.txt` or `context.md`. Recommend `context.md` for syntax highlighting and consistency with future Markdown transcripts. The transcript file in this app is currently `.txt`; revisit if user wants symmetry.
2. **Rollback symmetry.** If the move-source step fails after both transcript and context.md are written, rollback deletes both (mirror the existing transcript-rollback logic).
3. **`AuditLogEntry.swift`** — add `contextAttached: Bool?` (nil for entries written by older app versions; explicit true/false for new entries) and `organizationName: String?`. Bump `schemaVersion` to 2. Migration: old entries decode to nil values for the new fields — display as "—" in the UI.
4. **`AuditLogStore.swift`** — schema-2 migration in the decoder: if file is schema 1, decode entries with the new fields defaulted to nil, then save back as schema 2 on next write. Per `development-lifecycle.md` §6, one-way only.
5. **`AuditLogRow.swift`** — surface the new fields. Format: append `· Context: yes (Acme)` or `· Context: no` to the success row's subtitle.
6. **Tests** (`JotTests/Features/Pipeline/` and `JotTests/Features/AuditLog/`):
   - Unit: `FileOrganizerTests` — context.md written when context non-empty; not written when empty/nil; collision suffix still works. `AuditLogEntryTests` — schema-1 → schema-2 migration round-trip.
   - Integration: `PipelineOutputArtifactsIntegrationTests` — file in with context → assert directory contains audio + transcript + context.md with exact compiled bytes. `AuditLogPersistenceIntegrationTests` — write schema-1 file on disk, instantiate store, assert it loads and re-saves as schema 2.

**Deliverable:** A processed meeting folder contains: original audio (moved), transcript, and `context.md`. Audit log row reads e.g. `Transcribed '…' (1m 24s) · Context: yes (Acme)`.

---

## 8. Phase H — Release + tighten

**Goal:** End-to-end the feature behind a single demoable release.

1. **Cross-phase smoke test.** A new `JotTests/Features/MeetingContext/EndToEndIntegrationTests.swift` that walks the full path: create org → start meeting via prompter → edit during recording → land file → assert request body, output folder contents, and audit log entry in one test.
2. **Backwards-compat smoke test.** A user with zero orgs and never-touched Add Context settings should see no behavioral change from v0.1.7 except the new sidebar tab. Add a regression test (`LegacyNoContextFlowTests`) that drops a file with no `MeetingContextStore.pending` and asserts the request body has no `prompt` field and the output folder has no `context.md`.
3. **Docs.** Update `README.md` (if it exists — verify; otherwise skip) with a short "Context" section and a screenshot of the new tab.
4. **CHANGELOG.** New entry `v0.2.0 — Context`. Highlight: org profiles, per-meeting context, compiled prompt sent to Whisper-compatible endpoints, `context.md` artifact.
5. **Versioning.** Minor bump — this is a feature, not a fix (per `development-lifecycle.md` §5.1, MINOR for new features under 1.x). Tag `v0.2.0` ships the whole milestone in one Sparkle update.
6. **Verification before tag.** Per `coding-instructions.md` §8 ("Verify, don't assert"): build the Release configuration, install over the running v0.1.7, walk the happy path once with a real Groq/OpenAI key on a real meeting, and check the output folder + audit log before tagging.

**Deliverable:** `v0.2.0` reaches the user's installed Jot via Sparkle. The Context tab is live, an organization can be created, a meeting can be recorded with that org, and the resulting folder + audit log show that the context was attached.

---

## Out of scope (per PRD §3 + implementation triage)

- LLM summarization of the transcript using the context (PRD §3).
- Speaker diarization (PRD §3).
- Cloud sync of organization profiles (PRD §3).
- A "strict mode" toggle that *refuses* to transcribe when context compilation fails (PRD §9 mentions it as a behavior switch — defer to v0.3.x unless the user asks). v0.2.0 ships the soft path: compile-failures log and proceed with empty context.
- A provider-capability matrix that detects which endpoints support `prompt` and surfaces a warning if not. Endpoints today either accept the field or silently ignore it; we log inclusion and call it good for v1.
- Bulk import/export of organization profiles (CSV/JSON). One-off manual editing in the new tab is enough for v1.

---

## Phase → release mapping

| Phase | Deliverable | Branch | Tag |
|---|---|---|---|
| A | Org model + store (no UI) | `feat/organizations-store` | — |
| B | Context tab live (CRUD) | `feat/context-tab` | — |
| C | Context compiler + snapshot store | `feat/context-compiler` | — |
| D | Start-flow integration | `feat/meeting-start-context` | — |
| E | In-recording editor | `feat/current-meeting-editor` | — |
| F | Pipeline + API wiring | `feat/transcription-prompt` | — |
| G | Output artifact + audit log | `feat/context-artifact` | — |
| H | E2E test + release prep | `release/v0.2.0` | `v0.2.0` |

Each phase is its own PR, reviewed and merged into `main` before the next starts. No phase is shippable on its own — the cumulative behavior is gated behind Phase F (pipeline wiring) anyway. Tag only after Phase H verification.

---

## Open questions (resolve during Phase A kickoff)

1. **Context-artifact filename.** `context.md` (recommended, see Phase G.1) vs. `<meetingName>-context.md`. The latter mirrors the existing transcript naming.
2. **`MeetingNameStore` vs `MeetingContextStore`.** Extend the existing store in-place vs. wrap it. Recommend wrap-and-deprecate so the diff is reviewable and the legacy code stays compileable through Phase E.
3. **System prefix wording.** The exact first-line string for the compiled context (Phase C.2 step 1). Suggest something terse and Whisper-friendly: `"Transcription context. Names and terms used in this audio:"` — pick during Phase C impl.
