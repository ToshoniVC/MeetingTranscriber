# Jot - Implementation Plan: Claude Code Meeting Notes

Derived from [../PRD/CreateClaudeCodeMeetingNotes_PRD_2026_05_28.md](../PRD/CreateClaudeCodeMeetingNotes_PRD_2026_05_28.md). This plan adds an optional post-Notion trigger that fires a Claude Code routine to generate meeting notes inside the Notion page created by Jot.

Scope guard: Jot only triggers the configured Claude Code routine API call. Jot does not generate, edit, validate, or post-process meeting notes itself.

---

## 0. Guiding constraints

- Additive and opt-in: when the Claude Code toggle is OFF, app behavior is unchanged.
- Trigger order is strict:
  1. Transcript succeeds
  2. Notion page creation succeeds
  3. Claude Code routine fire call is sent
- Claude Code failure must not break core pipeline success.
- Endpoint and token are user-configured in Settings.
- Token must be stored in Keychain, never plaintext.
- Request contract must match PRD/API example:
  - `Authorization: Bearer <token>`
  - `anthropic-version: 2023-06-01`
  - `anthropic-beta: experimental-cc-routine-2026-04-01`
  - JSON body with `text`

---

## 0.5 Proposed file additions

```
Jot/
├── Core/
│   └── Settings/
│       └── AppSettings.swift                        # + claudeCodeNotesEnabled, + claudeCodeEndpoint, + claudeCodeToken, + claudeCodeExtraText
│
├── Features/
│   ├── ClaudeCode/
│   │   ├── ClaudeCodeRoutineClient.swift            # concrete HTTP client
│   │   ├── ClaudeCodeRoutineConfig.swift            # endpoint/token/headers payload config
│   │   ├── ClaudeCodeRoutineRequest.swift           # Encodable body model
│   │   ├── ClaudeCodeRoutineError.swift             # typed errors
│   │   └── ClaudeCodeValidation.swift               # pure validation
│   │
│   ├── Settings/
│   │   └── ClaudeCodeSection.swift                  # settings UI + setup guide + test checklist text
│   │
│   └── Pipeline/
│       └── ProcessingPipeline.swift                 # post-Notion fire-call hook
│
└── JotTests/
    ├── Features/ClaudeCode/
    ├── Features/Pipeline/
    └── Features/Settings/
```

---

## 1. Phase A - Settings model and secret handling

Goal: persist and validate Claude Code trigger configuration.

1. Extend `AppSettings` with:
   - `claudeCodeNotesEnabled: Bool` (default false)
   - `claudeCodeEndpoint: String`
   - `claudeCodeExtraText: String`
   - `claudeCodeToken: String?` (Keychain-backed)
2. Add dedicated Keychain account key for Claude Code token.
3. Add `ClaudeCodeRoutineConfig` snapshot model used by runtime.
4. Add `ClaudeCodeValidation` with states:
   - `.disabled`
   - `.misconfigured(reason)`
   - `.ready(config)`
5. Tests:
   - persistence round-trip for toggle/endpoint/extra text
   - Keychain token read/write/delete
   - validation branch coverage (blank endpoint, malformed URL, blank token)

Deliverable: safe and deterministic configuration state, no network required.

---

## 2. Phase B - Claude Code routine fire client

Goal: implement and test the POST fire call contract exactly.

1. Implement `ClaudeCodeRoutineClient.fire(...)` using `URLSession`.
2. Required request shape:
   - `POST <configured endpoint>`
   - Headers:
     - `Authorization: Bearer <token>`
     - `anthropic-version: 2023-06-01`
     - `anthropic-beta: experimental-cc-routine-2026-04-01`
     - `Content-Type: application/json`
   - Body: `{ "text": "<configured optional text>" }`
3. Implement `ClaudeCodeRoutineError` mapping for:
   - unauthorized
   - invalid endpoint
   - bad request
   - rate limited
   - server error
   - transport error
4. Keep retry behavior minimal for this phase: one attempt by default.
5. URLProtocol-based tests:
   - exact headers included
   - exact body key/value emitted
   - empty text allowed
   - status mapping coverage (401/400/429/500)

Deliverable: reliable, test-covered fire client with correct API contract.

---

## 3. Phase C - Settings UI and setup guidance

Goal: make configuration usable and self-explanatory in-app.

1. Add `ClaudeCodeSection` to Settings with:
   - enable toggle
   - routine endpoint field
   - token secure field
   - optional extra text field
2. Add in-app setup guidance matching PRD requirements:
   - create/select Claude Code routine with Notion access
   - copy routine fire endpoint into Jot
   - create/copy API token with fire permission
   - confirm Notion integration is configured first
   - optional extra text behavior
3. Add short in-app checklist:
   - run test meeting
   - confirm Notion page created
   - confirm fire request sent
   - confirm notes appear in Notion page
4. Show validation status:
   - disabled
   - setup needed
   - ready

Deliverable: users can configure and understand prerequisites without external docs.

---

## 4. Phase D - Pipeline wiring (post-Notion trigger)

Goal: fire the routine only after Notion page creation succeeds.

1. Add a post-Notion hook in `ProcessingPipeline` (or coordinator orchestration layer).
2. Enforce trigger preconditions:
   - transcript success
   - notion page success
   - claude code toggle on
   - valid endpoint/token config
3. Compose request text:
   - base from `claudeCodeExtraText`
   - optionally append Notion page URL or identifier if chosen integration mode requires it
4. Failure behavior:
   - do not alter transcript/notion completion outcomes
   - emit audit/log signal for fire success/failure

Deliverable: routine trigger runs at the right time and cannot regress core processing.

---

## 5. Phase E - Logging, audit visibility, and safety hardening

Goal: provide observability while keeping secrets safe.

1. Add Claude Code logging category (`Log.claudeCode`).
2. Log outcomes with non-secret diagnostics only:
   - endpoint host
   - status code
   - sanitized error summary
3. Ensure token redaction everywhere.
4. Optionally add compact audit status annotations:
   - skipped (disabled/misconfigured)
   - fired
   - failed
5. Tests for redaction and outcome-state reporting.

Deliverable: users can diagnose integration failures without compromising credentials.

---

## 6. Phase F - End-to-end verification and release prep

Goal: ship the feature safely.

1. Integration tests:
   - transcript + notion success -> routine fire request issued
   - exact request headers/body asserted
2. Regression tests:
   - toggle OFF -> no routine fire request
   - notion failure -> no routine fire request
3. Failure matrix:
   - Claude Code 401/429/500 does not fail core meeting processing
4. Manual smoke check:
   - configure endpoint/token
   - run real meeting through Notion flow
   - verify routine fires and notes appear in Notion page

Deliverable: release-ready integration with clear confidence in happy and failure paths.

---

## Out of scope

- In-app generation of meeting notes
- Validation/rewriting of routine-generated notes
- Multi-provider routine APIs
- Workflow orchestration beyond one fire call per meeting
- Bi-directional sync from Notion/Claude Code back into Jot

---

## Milestone mapping

- M1: Phase A (settings + validation)
- M2: Phase B (routine fire client)
- M3: Phase C + D (UI/setup guidance + pipeline wiring)
- M4: Phase E + F (observability + verification/release)

Each phase lands as its own PR; user-visible functionality is complete after Phase D.
