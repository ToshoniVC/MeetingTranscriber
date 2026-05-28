# Code Review Feedback - 2026-05-28

## Scope

This review covers the current Jot codebase with emphasis on:

- alignment with [Claude/coding-instructions.md](../Claude/coding-instructions.md)
- implementation status vs recent Notion and Claude Code PRDs
- runtime risk in security, pipeline correctness, and observability

Test status at review time:

- Full suite passed: 384 tests across 48 suites (`xcodebuild test -project Jot.xcodeproj -scheme Jot -destination 'platform=macOS'`).

---

## Findings (ordered by severity)

## 1. Critical - Secret storage implementation conflicts with project security policy

Evidence:

- [Claude/coding-instructions.md](../Claude/coding-instructions.md#L43) explicitly requires shipping-app secrets in macOS Keychain (`SecItem*`), never config files.
- [Jot/Core/Settings/Keychain.swift](../Jot/Core/Settings/Keychain.swift#L5) and [Jot/Core/Settings/Keychain.swift](../Jot/Core/Settings/Keychain.swift#L25) implement file-backed JSON secret storage under Application Support instead of macOS Keychain.

Risk:

- Direct policy mismatch on non-negotiable secret handling guidance.
- Security posture depends on file permissions and local-process trust assumptions rather than platform credential storage.

Recommendation:

- Restore true Keychain-backed implementation for production path.
- If ad-hoc-signing ergonomics are still needed for dev loops, gate file-backed storage to explicit debug/testing mode only and document that as an intentional exception.

---

## 2. High - Notion feature is not wired into the transcript success pipeline

Evidence:

- Notion writer exists: [Jot/Features/Notion/NotionMeetingWriter.swift](../Jot/Features/Notion/NotionMeetingWriter.swift#L24), [Jot/Features/Notion/NotionClient.swift](../Jot/Features/Notion/NotionClient.swift#L27).
- Runtime callsite appears only in Settings connection test: [Jot/Features/Settings/NotionSection.swift](../Jot/Features/Settings/NotionSection.swift#L134).
- No Notion references in pipeline runtime path (grep over `Jot/Features/Pipeline/**` found none).

Risk:

- Product behavior in Notion PRD (create page after transcript success) is not currently delivered by runtime flow.
- Users can configure/test Notion but receive no automatic meeting page creation.

Recommendation:

- Add explicit post-success pipeline hook (or coordinator hook) to call Notion writer.
- Ensure failures are non-blocking and logged, per PRD constraints.

---

## 3. High - Keychain write/delete errors are silently swallowed

Evidence:

- [Claude/coding-instructions.md](../Claude/coding-instructions.md#L72) discourages hiding failures with `try?` unless nil is the correct outcome.
- Secret mutations in [Jot/Core/Settings/AppSettings.swift](../Jot/Core/Settings/AppSettings.swift#L110) and [Jot/Core/Settings/AppSettings.swift](../Jot/Core/Settings/AppSettings.swift#L124) use `try?` for token writes/deletes.

Risk:

- Credential persistence failures can occur without user feedback.
- UI may appear to accept credentials while underlying storage fails.

Recommendation:

- Replace silent `try?` with `do/catch` and surface deterministic error state in Settings.
- Add audit/log signal for failed secret writes with no secret value exposure.

---

## 4. Medium - Pipeline settings observation does not react to secret changes at runtime

Evidence:

- [Jot/Features/Pipeline/PipelineCoordinator.swift](../Jot/Features/Pipeline/PipelineCoordinator.swift#L103) states API key is computed/non-observable and relies on user action/relaunch semantics.

Risk:

- Changing credentials in Settings may not reconfigure running pipeline immediately.
- Unexpected mismatch between UI state and runtime behavior.

Recommendation:

- Introduce explicit pipeline restart trigger on secret changes (e.g., mutation callback from settings section or coordinator signal).

---

## 5. Medium - Standing instruction document is outdated vs actual product direction

Evidence:

- [Claude/coding-instructions.md](../Claude/coding-instructions.md#L9) still describes OpenRouter summarization + markdown-writing flow and references `slides.html` as primary design.
- Current active PRDs and implemented features emphasize transcription pipeline + context + Notion bridge.

Risk:

- Future implementation guidance can drift or regress if contributors follow stale top-level instructions.

Recommendation:

- Refresh section 1 of coding-instructions to reflect current source of truth (active PRDs + current implementation plan) and current feature scope.

---

## Coding-Instructions Alignment Matrix

| Instruction area | Expected | Current status | Notes |
|---|---|---|---|
| Secrets in macOS Keychain | Required (`SecItem*`) | Not compliant | File-backed JSON storage currently used in `Keychain.swift`. |
| No hidden `try?` failures | Strong guidance | Partially non-compliant | Several `try?` usages are benign, but secret writes/deletes should not be silent. |
| Feature-driven architecture | Required | Mostly compliant | Notion code isolated under `Features/Notion`, settings under feature settings section. |
| Every feature ships tests | Required | Mostly compliant | Broad test coverage is strong; Notion pipeline integration tests absent because runtime integration is absent. |
| Verify with full test run | Required | Compliant at review time | Full suite passed (384 tests). |

---

## Positive Notes

- Test suite health is excellent (384 passing tests).
- Notion client/payload modeling is well factored and test-oriented.
- Feature folder decomposition remains consistent with architecture guidance.

---

## Suggested Remediation Order

1. Fix secret storage policy mismatch (Keychain implementation path).
2. Wire Notion creation into pipeline success path.
3. Remove silent secret-write failure handling.
4. Add runtime reconfiguration trigger for secret changes.
5. Update `coding-instructions.md` to current product direction.
