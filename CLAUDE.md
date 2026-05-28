# Jot — Claude Brief

Auto-loaded by Claude Code at session start. The full standing instructions live in [`Claude/coding-instructions.md`](Claude/coding-instructions.md) and [`Claude/development-lifecycle.md`](Claude/development-lifecycle.md) — imported below.

@Claude/coding-instructions.md
@Claude/development-lifecycle.md

## Active spec & plan

- **Active PRD:** [`PRD/ManualUpload_PRD_2026_05_28.md`](PRD/ManualUpload_PRD_2026_05_28.md) — feature spec for manually uploading `.mp3` or `.mp4` files and routing them through the existing watcher → transcription pipeline.
- **Active implementation plan:** [`Claude/implementation-plan.md`](Claude/implementation-plan.md) — phased build plan for the active PRD.
- **Backlog:** [`PRD/Backlog.md`](PRD/Backlog.md).

## Archive

Foundation specs and shipped-milestone plans. Useful for historical context, not the source of truth for active work.

- [`PRD/archive/MeetingTranscriber_PRD_v2026_05_27.md`](PRD/archive/MeetingTranscriber_PRD_v2026_05_27.md) — original v1 PRD (menu-bar app + folder watcher + OpenAI-compatible transcription + audit log + settings). Shipped through v0.1.7.
- [`Claude/archive/implementation-plan_v2026_05_27.md`](Claude/archive/implementation-plan_v2026_05_27.md) — original phased build plan for that PRD (Phases 0–9, M1–M4).
- [`PRD/archive/AddContext_PRD_2026_05_28.md`](PRD/archive/AddContext_PRD_2026_05_28.md) — Add Context PRD (organization profiles + per-meeting context + compiled Whisper prompt + `context.md` artifact). Shipped in v0.2.x.
- [`Claude/archive/implementation-plan_addContext_v2026_05_28.md`](Claude/archive/implementation-plan_addContext_v2026_05_28.md) — phased build plan for the Add Context PRD (Phases A–H).
- [`PRD/archive/CreateNotionMeeting_PRD_2026_05_28.md`](PRD/archive/CreateNotionMeeting_PRD_2026_05_28.md) — Notion meeting-creation bridge PRD (creates a new page in a configured Notion database with transcript + context toggles). Shipped in v0.3.0.
- [`Claude/archive/implementation-plan_createNotionMeeting_v2026_05_28.md`](Claude/archive/implementation-plan_createNotionMeeting_v2026_05_28.md) — phased build plan for the Notion meeting-creation PRD (Phases A–F).
- [`PRD/archive/CreateClaudeCodeMeetingNotes_PRD_2026_05_28.md`](PRD/archive/CreateClaudeCodeMeetingNotes_PRD_2026_05_28.md) — Claude Code routine trigger PRD (post-Notion fire that generates meeting notes inside the page). Shipped in v0.4.x.
- [`Claude/archive/implementation-plan_claudeCodeMeetingNotes_v2026_05_28.md`](Claude/archive/implementation-plan_claudeCodeMeetingNotes_v2026_05_28.md) — phased build plan for the Claude Code Meeting Notes PRD (Phases A–F).
