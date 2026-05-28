# Create Claude Code Meeting Notes PRD - Jot
Date: 2026-05-28
Status: Draft
Owner: Product

## 1. Summary

Add an optional post-processing integration that triggers a Claude Code routine after Jot successfully creates a Notion meeting page.

The routine is responsible for generating meeting notes inside that Notion page based on the transcript and context already stored there.

Jot should only fire the configured API call and pass the minimum required payload. Jot should not generate notes itself.

## 2. Goals

- Add a new Settings section for Claude Code routine integration.
- Allow users to configure:
  - Routine fire endpoint URL
  - API bearer token
  - Optional static text appended to the routine call body
- Trigger the Claude Code routine only after:
  1. Transcript generation succeeds
  2. Notion meeting page creation succeeds
- Send one authenticated HTTP POST to the configured Claude Code routine endpoint.
- Keep Jot's role limited to triggering the routine; no additional note generation logic in Jot.

## 3. Non-Goals

- No in-app meeting notes generation by Jot.
- No replacement of the Notion integration flow.
- No orchestration of multi-step AI workflows inside Jot.
- No parsing/validation of generated notes content returned by Claude Code.

## 4. Product Behavior

### 4.1 Settings UI

Add a Claude Code section in Settings with:

- Enable automatic meeting notes (toggle)
- Claude Code routine endpoint URL
- Claude Code API token (secure field)
- Optional "extra instruction text" field sent as request body `text`

Behavior:

- If toggle is OFF, no Claude Code calls are made.
- If toggle is ON but endpoint/token are missing or invalid, Jot should surface clear validation and skip firing.
- If toggle is ON and valid, Jot fires the routine when prerequisites are met.

### 4.2 Claude Code Setup Guidance (In-App)

The Settings section should include a concise "How to set up Claude Code" guide so users can complete the external prerequisites correctly.

The guide should explain:

1. Create or choose a Claude Code routine that can access Notion and write into the target meeting page.
2. Copy the routine fire endpoint URL (format: `/v1/claude_code/routines/<trigger_id>/fire`) into Jot.
3. Create or copy an API token with permission to fire the routine.
4. Confirm Notion integration is already configured in Jot and meeting pages are being created.
5. Optionally add extra instruction text that gets appended as request body `text`.

The guide should also include a short test checklist:

- Trigger a test meeting.
- Verify Jot creates the Notion page.
- Verify Jot sends the Claude Code fire call.
- Verify Claude Code writes notes into the Notion page.

### 4.3 Trigger Point and Order

Trigger only after successful Notion page creation for a meeting.

Required sequence:

1. Transcript generated
2. Notion page created
3. Claude Code routine fire call sent

No fire call on:

- Transcript failure
- Notion page creation failure
- Disabled feature toggle

### 4.4 API Contract

Default request pattern (configurable URL):

```bash
POST https://api.anthropic.com/v1/claude_code/routines/<trigger_id>/fire
Authorization: Bearer <token>
anthropic-version: 2023-06-01
anthropic-beta: experimental-cc-routine-2026-04-01
Content-Type: application/json
Body: {"text":"optional extra turn appended to the session"}
```

Baseline headers required:

- `Authorization: Bearer <token>`
- `anthropic-version: 2023-06-01`
- `anthropic-beta: experimental-cc-routine-2026-04-01`
- `Content-Type: application/json`

Body rules:

- Send JSON object with `text` field.
- `text` may be empty if user has not configured extra instruction text.

## 5. Integration Contract with Notion Flow

The Claude Code routine should operate against the Notion page created in the prior step.

Minimum requirement for Jot-to-routine handoff:

- Ensure the routine can identify the new Notion meeting page and produce notes there.

Implementation options (choose one during build, keep PRD scope fixed):

- Include Notion page identifier/URL in the `text` payload, or
- Depend on routine-side retrieval strategy if it can infer the latest page.

Jot scope remains limited to firing the routine; routine internals are external.

## 6. Validation and Error Handling

Validation:

- Claude Code fire call executes only when:
  - Toggle ON
  - Endpoint configured
  - Token configured
  - Notion page creation succeeded

Error handling:

- Claude Code API failures must not break core Jot pipeline outputs (audio + transcript + context + Notion page if already created).
- Log failures with actionable diagnostics (status code, endpoint host, non-secret error body summary).
- Never log secrets or full bearer token values.

Retry behavior:

- Keep retry strategy simple for this phase (at most one retry on transient network failure).

## 7. Privacy and Security

- Store Claude Code token securely (same secret-handling posture as API keys).
- Do not store token in plaintext on disk.
- Redact token from logs and diagnostics.
- Send only required routine payload data.

## 8. Acceptance Criteria

1. Settings contains an "automatic meeting notes" toggle for Claude Code integration.
2. User can configure routine endpoint URL and secure API token.
3. User can optionally configure extra instruction text sent as JSON `text`.
4. Settings includes setup instructions for Claude Code prerequisites and a basic end-to-end test checklist.
5. When transcript and Notion page creation both succeed, Jot sends one POST fire request to the configured routine endpoint.
6. Request contains required headers:
   - Authorization bearer
   - anthropic-version
   - anthropic-beta
   - Content-Type JSON
7. Request body includes `text` field.
8. If Claude Code call fails, Jot still treats transcript/notion creation outcomes independently and does not regress core pipeline behavior.
9. No meeting notes generation logic is added inside Jot.

## 9. Out of Scope

- Editing or validating Claude Code routine output in Jot.
- Scheduling or queue-management of routine runs beyond per-meeting fire.
- Multi-provider AI abstraction for this phase.

## 10. Suggested Implementation Sequence

1. Add Claude Code settings model and secure token storage.
2. Add Settings UI for toggle, endpoint, token, optional text.
3. Add post-Notion trigger step in pipeline.
4. Implement fire-call client with required headers/body.
5. Add logging/error handling that cannot block existing success path.
6. Add tests for enabled/disabled, success/failure, and header/body correctness.
