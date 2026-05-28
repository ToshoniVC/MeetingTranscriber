# Create Notion Meeting PRD - Jot
Date: 2026-05-28
Status: Draft
Owner: Product

## 1. Summary

Add an optional Notion integration that creates a new meeting page in a configured Notion database whenever Jot finishes a transcript.

This feature is strictly a delivery bridge from Jot into Notion. It should only create the meeting page and insert the generated transcript plus compiled context in predefined sections.

## 2. Goals

- Add a new setting in Jot Settings to enable/disable Notion meeting creation.
- When enabled, allow configuration of:
  - Notion MCP connection
  - Target Notion database for meeting pages
- On each successful transcript completion, create a new page in the configured Notion database.
- In the new page body, create exactly three toggle sections:
  1. Meeting Notes (left empty)
  2. Meeting Transcript (filled with Jot transcript)
  3. Additional Context (filled with Jot compiled context)

## 3. Non-Goals

- No summarization or action-item extraction.
- No edits to transcript or context content.
- No post-processing of the Notion page beyond initial creation.
- No attempt to auto-fill Meeting Notes.
- No additional Notion automation logic in this feature.

## 4. Product Behavior

### 4.1 Settings UI

Add a Notion section to Settings with:

- Enable Notion meeting creation (toggle)
- Notion MCP connection configuration
- Target database selector/input

Behavior:

- If toggle is OFF, Jot does nothing with Notion.
- If toggle is ON but configuration is incomplete or invalid, Jot should surface a clear validation/error state and skip Notion writes.
- If toggle is ON and configuration is valid, Jot will attempt page creation after each successful transcript.

### 4.2 Trigger Point

Trigger only after Jot has successfully completed transcript generation for a meeting.

No trigger on:

- Failed transcription
- In-progress audio
- Manual retries that still fail

### 4.3 Notion Page Creation

For each successfully processed meeting:

- Create one new page in the configured Notion database.
- Create exactly three toggle sections in page content:
  1. Meeting Notes
  2. Meeting Transcript
  3. Additional Context

Content rules:

- Meeting Notes: intentionally empty.
- Meeting Transcript: full transcript text produced by Jot.
- Additional Context: compiled context message produced by Jot.

No extra sections, no summary text, no generated interpretation.

## 5. Data and Mapping Requirements

Minimum payload from Jot pipeline to Notion writer:

- Meeting identifier/name
- Transcript text
- Compiled context text
- Timestamp metadata needed to create traceable records

Notion database target must be explicitly configured by user.

## 6. Validation and Error Handling

Validation:

- Notion feature toggle can only execute writes when MCP connection and database are configured.
- If required Notion config is missing, feature remains effectively disabled for writes even if toggle is ON.

Error handling:

- Notion failures must not block core Jot pipeline completion.
- Transcript and file organization remain source-of-truth success path.
- Notion write failures should be logged with actionable error detail.

Retry policy:

- Keep retry behavior minimal and explicit; avoid complex backoff orchestration in this phase.

## 7. Privacy and Security

- Reuse existing Jot security posture for secrets and settings.
- Do not store Notion credentials in plaintext.
- Only send data required for the meeting page:
  - Transcript text
  - Compiled context text
  - Minimal meeting metadata

## 8. Acceptance Criteria

1. Settings includes a Notion toggle to enable/disable meeting creation.
2. When enabled, user can configure Notion MCP connection and target database.
3. On successful transcript completion, Jot creates one new page in the configured Notion database.
4. New page contains exactly three toggle sections named:
   - Meeting Notes
   - Meeting Transcript
   - Additional Context
5. Meeting Notes is empty.
6. Meeting Transcript contains the generated transcript.
7. Additional Context contains the compiled context message.
8. No summary or other generated content is added by Jot.
9. Notion failures do not break transcript completion or file output.

## 9. Out of Scope

- AI summarization in Notion.
- Action item extraction.
- Bi-directional sync from Notion back into Jot.
- Rich templating beyond the three required toggle sections.

## 10. Suggested Implementation Sequence

1. Add Notion settings model + UI toggle.
2. Add MCP connection and database configuration fields.
3. Add Notion writer interface in pipeline post-transcript success path.
4. Implement page creation with three required toggle sections.
5. Add logging and failure handling that does not affect core pipeline success.
6. Add unit/integration tests for enabled/disabled behavior and payload correctness.
