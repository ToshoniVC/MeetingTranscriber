# Manual Upload PRD - Jot
Date: 2026-05-28
Status: Draft
Owner: Product

## 1. Summary

Add manual file upload functionality so users can import an `.mp3` or `.mp4` file and have Jot process it as if a recording had just finished naturally.

If the uploaded file is video (`.mp4`), Jot must first extract/convert audio to `.mp3`, then continue through the existing normal meeting pipeline (transcription, organization, audit logging, optional Notion/Claude Code downstream hooks).

## 2. Goals

- Let user manually upload media files directly from the app.
- Support at minimum:
  - `.mp3` (already-audio path)
  - `.mp4` (video path requiring audio extraction/conversion to `.mp3`)
- After upload preparation, route the file through the same processing path as watcher-triggered recordings.
- Preserve existing behavior and outputs:
  - transcript generation
  - meeting folder creation
  - source media copy/move behavior defined by pipeline
  - context handling
  - audit log visibility
  - optional Notion/Claude Code automation if configured

## 3. Non-Goals

- No full media editor UI.
- No support for arbitrary video formats in this phase (only `.mp4`).
- No parallel multi-file bulk upload in this phase.
- No new transcription logic separate from existing pipeline.

## 4. User Experience Requirements

### 4.1 Entry Point

Add a clear manual-upload entry point in app UI (for example in Transcripts tab toolbar or Settings utility actions):

- "Upload Recording..."

### 4.2 File Picker

When user selects upload:

- Open native file picker.
- Allow choosing one file.
- Accept only `.mp3` and `.mp4`.

### 4.3 Metadata Prompt

Before processing starts, require the same minimum metadata needed for normal flow parity:

- Meeting name (required)
- Organization selection (if organization/context feature is active)
- Optional meeting-specific context

### 4.4 Processing Experience

- Show upload/import state in UI (preparing, converting, queued, processing).
- `.mp3`: proceed directly to normal processing flow.
- `.mp4`: convert/extract audio to `.mp3`, then proceed to normal processing flow.
- Errors are surfaced with clear user-facing messages and logged to audit log.

## 5. Functional Requirements

### 5.1 Media Handling

- For `.mp3` upload:
  - Stage file into pipeline intake path and process normally.
- For `.mp4` upload:
  - Extract audio and write `.mp3` output using a native/conventional macOS-compatible media path.
  - Use a deterministic temp/output staging location.
  - On conversion success, process resulting `.mp3` through normal flow.

### 5.2 Pipeline Integration

Manual upload must reuse existing pipeline orchestration rather than bypassing it.

Required result:

- Uploaded/converted file should behave as if watcher emitted a newly-ready recording.

This ensures all existing downstream behavior remains consistent.

### 5.3 Naming and Organization

- Uploaded meetings must follow the same naming conventions and collision handling as normal recordings.
- Final folder artifacts must match existing expectations (transcript + source audio + context artifact when applicable).

### 5.4 Audit Log

Add explicit audit events for manual upload lifecycle:

- upload selected
- conversion started/completed (for `.mp4`)
- conversion failed (if relevant)
- pipeline success/failure

## 6. Validation and Error Handling

Validation:

- Reject unsupported file types.
- Reject missing required metadata (for example blank meeting name).
- Reject inaccessible/unreadable file paths.

Error handling:

- Conversion failures must not crash app.
- Failed uploads must not block normal watcher-driven pipeline.
- Clear actionable messages shown in UI and logged.

## 7. Performance and Reliability

- Large file handling should avoid loading full media into memory when unnecessary.
- Temporary conversion artifacts must be cleaned up after success/failure.
- Manual upload should not degrade watcher responsiveness.

## 8. Privacy and Security

- Process uploads locally.
- Do not copy uploaded files into unexpected locations beyond required staging and normal output.
- Keep secret handling unchanged (no credential changes in this feature).

## 9. Acceptance Criteria

1. User can trigger "Upload Recording..." from app UI.
2. Picker accepts `.mp3` and `.mp4` and rejects unsupported formats.
3. Uploading `.mp3` routes file through normal pipeline and produces standard outputs.
4. Uploading `.mp4` converts/extracts audio to `.mp3` first, then runs through normal pipeline.
5. Manual-uploaded meetings appear in transcripts/audit log the same way watcher meetings do.
6. Existing context compilation and attachment behavior still applies for uploaded meetings.
7. Existing optional Notion and Claude Code hooks are triggered according to their normal prerequisites.
8. Conversion or processing errors are visible and non-fatal to the rest of the app.

## 10. Suggested Implementation Sequence

1. Add upload entry point + file picker UI.
2. Add manual upload staging service (single-file path).
3. Add `.mp4` to `.mp3` conversion service.
4. Integrate manual upload output into existing pipeline enqueue path.
5. Add audit log events for upload/conversion lifecycle.
6. Add tests for `.mp3` happy path, `.mp4` conversion path, and failure modes.

## 11. Testing Requirements

Unit tests:

- File type validation (`.mp3`, `.mp4`, unsupported cases)
- Conversion command/service behavior (success/failure mapping)
- Metadata validation for manual upload start

Integration tests:

- Upload `.mp3` -> normal end-to-end pipeline success
- Upload `.mp4` -> conversion -> normal end-to-end pipeline success
- Conversion failure path logs and surfaces error without pipeline regression
- Unsupported format path rejected before enqueue
