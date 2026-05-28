# Add Context PRD - Jot
Date: 2026-05-28
Status: Draft
Owner: Product

## 1. Summary

Add a new feature to improve transcription quality by allowing users to define and apply contextual data at two levels:

1. Organization-level context (reusable across meetings)
2. Meeting-level context (specific to one meeting)

This context is compiled and sent with the audio file to the transcription API (Whisper-compatible) when processing completes.

## 2. Goals

- Add a new 4th main tab in Jot: Custom Context
- Let users create and manage multiple Organizations
- Each organization stores a custom context profile (company, staff, projects, terminology, acronyms, etc.)
- Require both Meeting Name and Organization selection when starting a meeting
- Support:
  - Default organization
  - Empty organization option (for private/general calls)
- Allow optional Meeting-specific context before start
- Allow editing meeting metadata while recording:
  - Meeting name
  - Organization
  - Meeting-specific context
- On processing, send compiled context (organization + meeting) with audio to transcription endpoint
- Persist compiled context into the final output folder alongside source audio and transcript

## 3. Non-Goals

- No summarization or post-processing by LLM
- No speaker diarization in this phase
- No cloud sync for context profiles in this phase

## 4. UX Requirements

### 4.1 New 4th tab: Custom Context

Add a new tab to the main window sidebar:

1. Transcripts
2. Audit Log
3. Settings
4. Custom Context (new)

### 4.2 Custom Context Tab Structure

The tab should support:

- Organization list (left or top section)
- Organization details editor (main area)

Each organization has:

- Organization name (required, unique)
- Company name (optional)
- Staff names (optional list)
- Project names (optional list)
- Domain terms / glossary (optional list)
- Acronyms / expansions (optional list)
- Freeform context notes (optional multiline text)
- Is default organization toggle (only one org can be default)

System-provided special option:

- No Organization / empty organization for private calls

### 4.3 Meeting Start Flow Changes

When starting a meeting from hotkey flow:

Required inputs:
- Meeting name (required)
- Organization (required selection, but can be No Organization)

Optional input:
- Meeting-specific context (free text, optional)

Rules:
- If a default organization exists, preselect it
- User can switch to No Organization
- Meeting cannot start if meeting name is empty
- Meeting cannot start if organization is not selected

### 4.4 During Recording: Editable Meeting Metadata

While recording is active, user can open current meeting details and edit:

- Meeting name
- Organization
- Meeting-specific context

Edits must apply to the pending transcription context for the current recording.

## 5. Data Model Requirements

### 5.1 Organization Profile

Suggested fields:

- id: UUID
- name: String
- companyName: String?
- staffNames: [String]
- projectNames: [String]
- glossaryTerms: [String]
- acronyms: [AcronymEntry] (term + expansion)
- freeformNotes: String?
- isDefault: Bool
- createdAt: Date
- updatedAt: Date

### 5.2 Meeting Context Snapshot

Per active/recorded meeting:

- meetingName: String
- organizationId: UUID? (nil when No Organization selected)
- meetingSpecificContext: String?
- resolvedCompiledContext: String (final compiled text sent to API)
- lastEditedAt: Date

## 6. Context Compilation Rules

When file is sent for transcription, compile context in deterministic order:

1. System prefix/instructions for transcription context usage
2. Organization name / company
3. Staff names
4. Project names
5. Glossary + acronyms
6. Organization freeform notes
7. Meeting name
8. Meeting-specific context

Constraints:
- Trim whitespace and deduplicate repeated terms
- Enforce max character/token budget (configurable, safe default)
- If no org and no meeting context, compiled context may be empty
- Never include API keys or sensitive system config in context payload

## 7. Transcription Pipeline Changes

Current behavior:
- Send audio + model + response format

New behavior:
- Send audio + model + response format + compiled context field (provider-compatible prompt/context parameter)

Compatibility:
- Must remain compatible with OpenAI-compatible Whisper endpoints
- If provider does not support context field, fail gracefully or omit with warning based on provider capability mode
- Log whether context was included

## 8. Output Folder Artifacts

For each processed meeting folder, include:

- Original mp3/m4a/wav
- Transcript text file
- Context artifact file (new), for example:
  - context.txt or context.md
  - Contains exactly the compiled context sent for transcription

Purpose:
- Auditability and reproducibility of transcript quality inputs

## 9. Validation and Error Handling

Validation:
- Meeting name required before recording starts
- Organization must be selected (including explicit No Organization)
- Organization names must be unique
- Exactly one default organization max

Error handling:
- If context compilation fails, log detailed error and continue with empty context or block based on strict mode setting
- If context attachment rejected by endpoint, log API response and retry behavior remains unchanged
- App must never crash from malformed organization data

## 10. Privacy and Security

- Organization and meeting context stored locally on device
- API key remains in Keychain (unchanged)
- Context may include sensitive names; store in app data with same privacy posture as audit/transcript metadata
- Do not send any context unless tied to transcription request

## 11. Acceptance Criteria

1. Main window shows a 4th tab named Custom Context.
2. User can CRUD organizations and set one as default.
3. Start meeting flow requires meeting name and organization selection (including No Organization).
4. User can optionally provide meeting-specific context at start.
5. During recording, user can edit meeting name, organization, and meeting-specific context.
6. On processing, compiled context is sent with the audio transcription request when supported.
7. Final meeting folder contains transcript, source audio, and saved compiled context artifact.
8. Audit log records whether context was attached and which organization mode was used (named org vs No Organization).
9. Existing transcription-only workflows continue to function when no context is provided.

## 12. Rollout Notes

Recommended implementation phases:

1. Data model + persistence for organizations
2. Custom Context tab UI
3. Meeting start flow changes (required fields + optional context)
4. In-recording metadata editing
5. Pipeline/API context integration
6. Output artifact and audit enhancements
7. Tests and migration coverage

## 13. Testing Requirements

Unit tests:
- Organization validation
- Default organization exclusivity
- Context compilation ordering/deduplication/budget trimming
- Meeting metadata editing lifecycle

Integration tests:
- Start meeting with default org
- Start meeting with No Organization
- Update metadata during recording and verify final compiled context
- Verify context included in transcription request payload
- Verify context artifact written into final output folder
- Verify behavior when endpoint rejects context parameter
