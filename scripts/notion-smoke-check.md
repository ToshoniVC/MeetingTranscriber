# Notion v0.3.0 manual smoke check

Run once against the live Notion API before tagging `v0.3.0`. This is the
"verify, don't assert" step from [`coding-instructions.md`](../Claude/coding-instructions.md) §8 —
the test suite covers every code path via `URLProtocol` mocks, but we
want one real round-trip against `api.notion.com` to catch anything
the mocks paper over (real HTTP timing, real auth, real database
schema lookup).

This file is a runbook, not part of CI. Keep it next to `build-icons.swift`
so it sits with the other release-prep tooling.

---

## One-time setup

1. Create a Notion internal integration:
   - https://www.notion.so/profile/integrations → **+ New integration**.
   - Workspace: pick the one with a test database you don't mind
     polluting (a personal scratch workspace is ideal).
   - Capabilities: leave at the defaults (Read + Update + Insert content).
   - Copy the `secret_…` token.

2. Create a target Notion database:
   - New page → **Database — full page**.
   - Add a single title property (Notion creates one by default; rename
     it to "Name" or whatever you like).
   - Click `· · ·` → **Connections** → add your integration. (Without
     this share step, the integration sees a 404 even though the
     database exists.)
   - Copy the database ID from the URL — it's the 32-char hex segment
     between the slash and the `?v=` (e.g.,
     `https://www.notion.so/your-workspace/abc123…?v=…` → `abc123…`).

---

## The check

1. Open Jot's Settings → Notion section.
2. Toggle Notion ON.
3. Paste the token + database ID.
4. Click **Test connection** — the line below should flip to
   `Connected · <your database name>` in green within ~1s.
5. Press your recording hotkey, pick an organization, type a meeting
   name (e.g., `Notion v0.3.0 smoke`), and start.
6. Let the recording run for ~15s, then stop.
7. Wait for the audit-log row to land. It should:
   - Show the transcript was filed (the normal v0.2.x outcome).
   - Have a `Notion…` spinner subtitle briefly.
   - Resolve to a blue `Notion page` link.
8. Click the `Notion page` link. The new page should open in the
   browser with:
   - The meeting name as the page title.
   - **Meeting Notes** toggle (empty).
   - **Meeting Transcript** toggle (your transcript).
   - **Additional Context** toggle (the compiled context).

---

## Negative checks

These don't need to be re-run every release, but worth doing once on
the v0.3.0 branch:

- Token rejection: paste a clearly bad token, click **Test connection** —
  red `Notion token was rejected.` appears.
- Wrong database ID: paste a real-looking ID that doesn't exist — red
  `Notion database not found …` appears.
- Disabled toggle: flip Notion off, record a meeting — the audit row
  has the normal "filed" subtitle and no Notion suffix.

---

## What to do if any step fails

1. Open Console.app, filter on subsystem `com.toshonivc.jot` and
   category `notion` — the logs there carry the exact failure path.
2. The mocked integration tests cover every status code, so a live
   regression usually points to a Notion API contract change. Check
   https://developers.notion.com/changelog before chasing it as a Jot
   bug.
