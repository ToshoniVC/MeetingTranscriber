# Jot - Implementation Plan: Manual Upload

Derived from [../PRD/ManualUpload_PRD_2026_05_28.md](../PRD/ManualUpload_PRD_2026_05_28.md). This plan adds manual file upload functionality so users can import `.mp3` or `.mp4` files and have Jot process them through the existing meeting pipeline.

Scope guard: Jot only provides a file picker and staging layer; all downstream processing (transcription, organization, context, audit logging, Notion/Claude Code hooks) reuses the existing pipeline infrastructure.

---

## 0. Guiding constraints

- Additive and non-breaking: existing watcher-driven pipeline remains unchanged.
- Manual upload routes to the same `ProcessingPipeline` as watcher recordings.
- `.mp3` files proceed directly to transcription.
- `.mp4` files are converted to `.mp3` first, then proceed to transcription.
- Metadata collection is required before processing (meeting name, optional context).
- All error paths must be non-fatal and surfaced in UI + audit log.
- Temporary conversion artifacts are cleaned up after success/failure.

---

## 0.5 Proposed file additions

```
Jot/
├── Core/
│   └── Logging/
│       └── AuditLog.swift                           # + manual upload events
│
├── Features/
│   ├── Pipeline/
│   │   ├── ManualUploadStaging.swift                # file path validation + staging
│   │   ├── MediaConversionService.swift             # .mp4 → .mp3 via ffmpeg/AVFoundation
│   │   └── ProcessingPipeline.swift                 # + manual upload enqueue entry point
│   │
│   ├── Transcripts/
│   │   └── TranscriptsView.swift                    # + "Upload Recording..." button/action
│   │
│   └── Settings/
│       └── SettingsView.swift                       # optional: upload as utility action
│
└── JotTests/
    ├── Features/Pipeline/
    │   ├── ManualUploadStagingTests.swift
    │   ├── MediaConversionServiceTests.swift
    │   └── ManualUploadPipelineIntegrationTests.swift
    └── Features/Transcripts/
        └── TranscriptsViewTests.swift
```

---

## 1. Phase A - File picker and metadata collection UI

Goal: provide entry point and collect required upload context.

1. Add "Upload Recording..." action to Transcripts tab toolbar or Settings utility menu.
2. Implement file picker view/sheet:
   - Native NSSavePanel / file browser.
   - Filter to `.mp3` and `.mp4` only.
   - Allow single file selection.
   - Return selected file URL.
3. On file selection, show metadata prompt form:
   - Meeting name (text field, required, validate non-empty).
   - Organization selection (picker, populated from existing orgs if context feature active).
   - Optional meeting-specific context (text area, optional).
4. Metadata validation:
   - Reject blank meeting name.
   - Accept any organization or "default" if not configured.
5. Tests:
   - File picker integration (mocked NSSavePanel).
   - Metadata form validation (empty name rejected, non-empty accepted).
   - File type filtering (only `.mp3`/`.mp4` selectable).

Deliverable: UI entry point and validated metadata ready for staging.

---

## 2. Phase B - Manual upload staging service

Goal: validate and stage uploaded files for pipeline ingestion.

1. Implement `ManualUploadStaging` service with:
   - `validateFile(url: URL) -> Result<FileInfo, UploadError>`
     - Check file exists and is readable.
     - Extract file extension.
     - Validate extension is `.mp3` or `.mp4`.
     - Get file size (reject if suspiciously large, e.g. >500 MB).
   - `stageFile(url: URL, meetingName: String) -> Result<StagedFile, UploadError>`
     - Copy/move file to pipeline intake staging location.
     - Generate deterministic staging path with metadata.
     - Return staging record with original metadata.
2. Error types (`UploadError`):
   - `unsupportedFormat`
   - `fileNotFound`
   - `unreadableFile`
   - `fileTooLarge`
   - `stagingFailed`
3. Audit log integration:
   - Log "upload_selected" with file type and size.
   - Log "file_staged" with staging path.
4. Tests:
   - Valid `.mp3` file validated and staged successfully.
   - Valid `.mp4` file validated and staged successfully.
   - Unsupported file types rejected.
   - Missing files rejected.
   - File size limits enforced.
   - Staging path determinism verified.

Deliverable: validated and safely staged file ready for conversion or transcription.

---

## 3. Phase C - Media conversion service (.mp4 → .mp3)

Goal: extract audio from `.mp4` and produce `.mp3` output.

1. Implement `MediaConversionService` with:
   - `convertMP4ToMP3(inputURL: URL, outputURL: URL) -> Result<URL, ConversionError>`
     - Use native macOS tool (recommend `AVFoundation` for in-process, or `ffmpeg` if installed).
     - Stream/pipeline to avoid loading full video into memory.
     - Write `.mp3` output to specified location.
     - Return output URL on success.
2. Error types (`ConversionError`):
   - `toolNotAvailable` (ffmpeg not found, if using shell).
   - `invalidInputFile` (not decodable as video).
   - `conversionFailed(reason)`
   - `outputWriteFailed`
3. Conversion strategy options (pick one):
   - **Option A (preferred):** Use `AVAsset` + `AVAssetExportSession` (in-process, no external dependencies).
   - **Option B:** Shell out to `ffmpeg` (requires user installation or bundled binary).
4. Temporary file handling:
   - Generate unique temp output path (avoid collisions).
   - Clean up temp file if conversion fails.
   - Move/rename temp file to final location on success.
5. Audit log integration:
   - Log "conversion_started" with input filename.
   - Log "conversion_completed" with output size on success.
   - Log "conversion_failed" with error on failure.
6. Tests:
   - Mock `.mp4` file converted to `.mp3` successfully.
   - Invalid `.mp4` file rejected with clear error.
   - Temp file cleanup on success.
   - Temp file cleanup on failure.
   - Audio properties of output validated (is MP3, has audio stream).

Deliverable: reliable, tested audio conversion with clear error paths and cleanup.

---

## 4. Phase D - Pipeline integration (enqueue manual upload)

Goal: route staged/converted file into existing `ProcessingPipeline`.

1. Add manual upload entry point to `ProcessingPipeline`:
   - `enqueueManualUpload(stagedFile: StagedFile, metadata: UploadMetadata) async throws`
2. Implementation:
   - If staged file is `.mp3`, proceed directly to transcription step.
   - If staged file is `.mp4`, invoke `MediaConversionService` first.
   - On conversion success, proceed to transcription.
   - On conversion failure, surface error and audit log.
   - After conversion (if needed), construct a `RecordingInfo` model matching watcher expectations.
   - Enqueue to normal processing coordinator.
3. Integration points:
   - Reuse existing `RecordingInfo` / meeting folder creation logic.
   - Reuse existing transcription enqueue.
   - Reuse existing audit log (leverage existing events + new "manual_upload" namespace).
   - Apply configured organization and optional context.
   - Trigger downstream Notion/Claude Code hooks if configured.
4. Error handling:
   - Conversion failures surface in UI and audit log, do not crash pipeline.
   - Staging failures surface in UI and audit log.
   - Normal pipeline errors (transcription, organization failure) bubble up as usual.
5. Audit log integration:
   - Log "upload_enqueued" with meeting name and file type.
   - Leverage existing pipeline event log for transcription/org/notion/claudecode.
6. Tests:
   - Mock `.mp3` upload -> normal pipeline enqueue -> transcript generated.
   - Mock `.mp4` upload -> conversion -> pipeline enqueue -> transcript generated.
   - Conversion failure -> error surfaced, pipeline not blocked.
   - Normal pipeline failures treated as for any other flow.

Deliverable: manual uploads fully integrated into existing pipeline with no regression.

---

## 5. Phase E - UI state and progress feedback

Goal: provide user visibility into upload, conversion, and processing status.

1. Add upload state machine to Transcripts view or dedicated upload coordinator:
   - `.idle`
   - `.pickingFile`
   - `.collectingMetadata`
   - `.staging`
   - `.converting` (only for `.mp4`)
   - `.processing` (transcription in progress)
   - `.success(meetingURL)`
   - `.failed(error)`
2. Implement state-driven UI updates:
   - Show progress indicator during `.staging`, `.converting`, `.processing`.
   - Show error alert on `.failed`, allow dismiss.
   - Show success confirmation with meeting link on `.success`.
3. Cancellation:
   - Allow user to cancel during `.collecting metadata` and `.staging`.
   - If cancellation during `.converting` or `.processing`, attempt graceful interrupt.
4. Tests:
   - State transitions driven by service callbacks.
   - UI reflects each state appropriately.
   - Error state dismisses cleanly.

Deliverable: clear upload and processing feedback without blocking app.

---

## 6. Phase F - Logging, audit visibility, and safety hardening

Goal: observability and confidence in upload lifecycle.

1. Add manual upload logging category (`Log.manualUpload`).
2. Log events with non-sensitive diagnostics:
   - File type, size at selection.
   - Staging path (obfuscated user home).
   - Conversion duration and tool used.
   - Final enqueue timestamp.
3. Ensure no credential or full-path leakage.
4. Audit log compact annotations:
   - `manual_upload:file_selected` with type/size
   - `manual_upload:staged` with staging context
   - `manual_upload:conversion_started`, `_completed`, `_failed`
   - `manual_upload:enqueued`
   - Leverage existing `transcript`, `organization`, `notion`, `claudecode` event chains
5. Redaction pass:
   - User home directory paths redacted.
   - API keys/secrets not included anywhere.
6. Tests:
   - Log output does not contain sensitive paths or credentials.
   - All error conditions logged with actionable diagnostics.

Deliverable: users and admins can diagnose upload issues without security risk.

---

## 7. Phase G - End-to-end testing and release prep

Goal: confidence in happy path, failure paths, and no regression.

1. Integration tests covering:
   - `.mp3` upload happy path: pick → metadata → stage → enqueue → transcript → audit log.
   - `.mp4` upload happy path: pick → metadata → stage → convert → enqueue → transcript → audit log.
   - Unsupported format rejected at picker.
   - Metadata validation: blank name rejected, non-empty accepted.
   - Conversion failure: error surface, pipeline not enqueued.
   - Staging failure: error surfaced, pickup cancelled.
2. Regression tests:
   - Watcher-driven pipeline unaffected.
   - Normal transcription flow unaffected.
   - Notion integration unaffected (if configured).
   - Claude Code integration unaffected (if configured).
   - Audit log format unchanged.
3. Manual smoke check (QA):
   - Upload `.mp3` file → verify transcript generated and audit log shows upload event.
   - Upload `.mp4` file → verify audio extracted, transcript generated, audit log shows conversion event.
   - Upload corrupted `.mp4` file → verify graceful error and no pipeline hang.
   - Upload very large file → verify size limit enforced.
   - Cancel during metadata → verify no staging artifact left.
   - Trigger Notion + Claude Code with manual upload → verify downstream hooks run.
4. Documentation:
   - In-app guidance: upload button help text, supported formats, metadata fields.
   - Release notes: new feature, supported formats, limitations (no batch upload, `.mp4` only).

Deliverable: release-ready with user documentation, test coverage, and zero known regressions.

---

## Out of scope

- Bulk multi-file upload in this phase.
- Video format support beyond `.mp4`.
- Media editor or trimming UI.
- Conversion to formats other than `.mp3`.
- Resumable upload (assume reliable local file system).
- Deduplication of already-uploaded files.

---

## Milestone mapping

- **M1:** Phase A (picker + metadata UI)
- **M2:** Phase B (staging service)
- **M3:** Phase C (conversion service)
- **M4:** Phase D (pipeline integration)
- **M5:** Phase E (UI state/progress)
- **M6:** Phase F (logging + audit)
- **M7:** Phase G (E2E testing + release)

Each phase lands as its own PR or grouped logically; user-visible functionality complete after Phase D. Phases E–G are polish, observability, and confidence.
