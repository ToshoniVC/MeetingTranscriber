# Coding Instructions for Claude — Jot

> **How to use this file.** This is the standing brief Claude should read at the start of every coding session in this repo. To make Claude auto-load it, either copy this file to `CLAUDE.md` at the repo root, or add a one-liner `CLAUDE.md` that says `See Claude/coding-instructions.md`.

---

## 1. What this project is

A native macOS menu-bar utility (SwiftUI, Swift 5.9+, macOS 14+) that watches a folder for `.mp3` recordings produced by Audio Hijack, transcribes them with Groq (Whisper), summarizes them with OpenRouter (Claude), and writes Markdown to disk. Full design in [`slides.html`](../slides.html); phased build plan in [`implementation-plan.md`](./implementation-plan.md).

Read both before suggesting architecture changes.

---

## 2. Architectural Philosophy: Feature-Driven Design

This project uses **Feature/Domain-Driven Architecture**: code is organized by *what it does* (its business domain), not by *what it is* (its technical file type). No `Models/` + `Views/` + `Controllers/` split. No `Utils/` junk drawer.

Inside the Xcode target folder we use a three-folder skeleton — **`Core/`**, **`Shared/`**, and **`Features/`** — described by the rules below. The concrete realization for this project (the actual folder tree with real feature names) lives in [`implementation-plan.md`](./implementation-plan.md). Always cross-check that file before adding a new folder; if you need a folder that isn't there, propose adding it to the plan first.

### Rules

- **Every distinct feature/domain gets its own folder** under `Features/<FeatureName>/`. Both user-visible features and headless domains follow the same pattern. If you can name the responsibility in one noun, it's a feature.
- **A feature folder is self-contained.** It owns its own views, view-models, models, domain-specific services, and helpers. Cross-feature reach-ins are not allowed — if feature A needs something from feature B, that something is part of B's public surface (see access rules below) and gets called, not copied.
- **`Core/` is for app-wide infrastructure only.** App entrypoint, app-wide state, logging, single-instance services that every feature uses. If only one feature uses it, it does not belong in `Core/`.
- **`Shared/` is for universally reusable UI primitives only.** Generic buttons, layout wrappers, view modifiers with zero domain knowledge. If it has any domain knowledge, it belongs in a feature folder.
- **Nesting cap: 3–4 levels under the target folder.** Don't create deep hierarchies for their own sake — flatten.
- **Swift access modifiers replace barrel files.** There's no `index.ts` equivalent in Swift. Instead: types that are part of a feature's public surface are `internal` (the default — visible across the module) or `public`. Everything else is `fileprivate` or `private`. Be deliberate — most types should be `fileprivate`.
- **Tests mirror the source layout exactly** under `JotTests/`. See §6.

### Decision tree: "where does this file go?"

1. Is it the app entrypoint, app-wide config, or used by every feature? → `Core/`
2. Is it a generic UI primitive with zero domain knowledge? → `Shared/`
3. Otherwise it belongs to a feature → `Features/<FeatureName>/`. If no existing feature fits, create one. Don't lump it into `Core/` "for now."

---

## 3. Secrets — non-negotiable rules

- **Never commit secrets.** No API keys, tokens, passwords, signing certificates, or `.env` files in git. Ever. If you spot one in a diff, stop and flag it.
- **`.env` for development scripts only.** Auxiliary scripts (one-off transcription tests, eval harnesses) may read from a `.env` file at the repo root. That file is gitignored — verify the gitignore entry exists before introducing the file.
- **Keychain for the shipping app.** The actual macOS app stores `groqAPIKey` and `openRouterAPIKey` in the user's Keychain via `SecItemAdd` / `SecItemCopyMatching`, keyed on service `com.toshonivc.jot`. Never `UserDefaults`, never a plist, never a config file.
- **Provide a `.env.example`** with the variable names but empty values. That file *is* committed.
- **Never log a secret.** No `print(apiKey)`, no `logger.debug("token: \(token)")`. If you need to confirm a key loaded, log its length and last 4 chars at most.
- **Never echo a secret in shell output** when running Bash commands. Use env vars, not inline strings.

---

## 4. Git & commit hygiene — co-create workflow

The user reviews changes in VS Code's Source Control panel before anything reaches GitHub. Claude does **not** push, and does **not** open PRs. Both of those are user actions.

- **Never push.** No `git push`. No `gh pr create`. The user pushes from VS Code when they're satisfied.
- **Never commit directly to `main`.** For any change beyond a typo fix in a doc, create a feature branch first (`git checkout -b m2-watcher`, `git checkout -b fix/keychain-leak`, etc.). Branch names mirror the milestones in the implementation plan where applicable.
- **Leave changes for review.** Default mode: edit files and stop. Do not stage and do not commit unless the user asks. The user will see your edits live in VS Code's file explorer and the Source Control panel, decide what to keep, and commit themselves.
- **If asked to commit:** small, focused commits — one logical change each. Subject line ≤ 72 chars, imperative mood (`Add Keychain wrapper for API key storage`, `Fix race in folder watcher debounce`). Body explains *why*, not *what*.
- **Never `git add -A` or `git add .`** Add files by name after running `git status`.
- **Never force-push to `main`.** Force-push only on your own feature branches, and only when you understand what you're overwriting.
- **Don't bypass hooks.** No `--no-verify`. If a pre-commit hook fails, fix the underlying issue.
- **`.vscode/extensions.json` is committed** (it's a workspace recommendation, not a per-user setting). Other `.vscode/*.json` files are per-user and should be gitignored if they appear.

---

## 5. Swift / SwiftUI conventions

- **Concurrency.** All I/O is `async/await`. Long-lived mutable state lives in `actor`s. Never call `DispatchQueue.main.sync`. Never `.wait()` on a future.
- **No blocking on the main thread.** UI updates use `@MainActor`. Network and file I/O happen off-main and hop back via `await MainActor.run`.
- **Native APIs over libraries.** Prefer `URLSession`, `FSEvents`, `os.Logger`, `Keychain Services` to third-party packages. Pull in a dependency only with a one-line justification in the PR description.
- **No Combine unless there's a reason.** SwiftUI's `@Observable` + async sequences cover the cases we have.
- **Errors are typed.** Each subsystem defines its own `Error` enum (`TranscriptionError`, `WatcherError`, …). Never `throw NSError(...)`. Never swallow errors silently — at minimum log and surface to the UI.
- **No `try?` to hide failures.** Use `try?` only when `nil` is the genuinely correct response. Otherwise `do/catch` and handle the error.
- **No `print()` in shipping code.** Use `os.Logger` with subsystem `com.toshonivc.jot` and a per-component category.
- **File layout.** One type per file unless the types are tiny helpers. Folder organization is governed by §2 (Feature-Driven Design) and testing rules by §6.

---

## 6. Testing & PR gates

Tests are a hard requirement, not an afterthought. No PR ships without them.

- **Every feature ships with tests.** When you write a feature, you write its tests in the same PR. Both a **unit test** (the feature's logic in isolation, with collaborators mocked) and an **integration test** (the feature exercised end-to-end against its real boundaries — file system, URLSession with mocked `URLProtocol`, on-disk JSON store, etc.). Tests live under `JotTests/Features/` mirroring the source layout exactly (`Features/Pipeline/FileOrganizer.swift` → `JotTests/Features/Pipeline/FileOrganizerTests.swift` and `FileOrganizerIntegrationTests.swift`).
- **All tests pass before a PR is opened.** Run the full suite locally (`xcodebuild test -scheme Jot -destination 'platform=macOS'` or via Xcode's `⌘U`) and confirm green. A red suite is a blocker — fix the cause, don't `XCTSkip` it.
- **Python tooling uses a venv.** Anything under `scripts/` that's written in Python (eval harnesses, one-off transcription tests, CI helpers) runs inside a virtualenv. Create with `python3 -m venv .venv`, activate with `source .venv/bin/activate`, install deps from `scripts/requirements.txt`. The `.venv/` directory is gitignored. Never `pip install` into the system Python.
- **Swift testing has no venv equivalent.** XCTest runs inside the Xcode-managed toolchain — no setup needed. Don't invent one.
- **Test naming.** `test_<unit>_<condition>_<expectedResult>` (e.g., `test_fileOrganizer_whenDestinationExists_appendsTimestampSuffix`). Names should read as sentences.
- **No real network calls in tests.** Mock with `URLProtocol`. A test that needs the live Groq/OpenAI endpoint isn't a test — it's a manual smoke check, and it belongs in `scripts/`, not `JotTests/`.
- **No real Keychain writes in tests.** Inject a `KeychainProtocol` and use an in-memory fake.

---

## 7. macOS-specific rules

- **Stay sandboxed.** Don't disable the App Sandbox to make something work. If you need an entitlement, add it with a comment explaining why.
- **Security-scoped bookmarks** for any user-chosen folder that needs to survive a relaunch. Plain `URL`s won't have access after restart.
- **No audio drivers, ever.** The PRD is explicit: Jot does not install a virtual audio device, does not interpose on the audio stack, does not touch CoreAudio HAL. Audio Hijack owns recording.
- **`LSUIElement = YES`.** The app must not appear in the Dock or `Cmd+Tab`.
- **File watching uses `FSEvents` / `DispatchSourceFileSystemObject`.** No `Timer`-based polling of directory contents.

---

## 8. Working with Claude (workflow rules)

- **Read first, write second.** Before editing a file, read it. Before adding a new abstraction, search for an existing one.
- **Plan visible work.** For any change touching more than ~3 files, post a short plan first and wait for an ack.
- **Don't invent requirements.** If the PRD or implementation plan is silent on a question, ask — don't guess and ship.
- **Match the existing style.** If a file uses 4-space indents and trailing commas, your edits do too. Don't reformat unrelated code.
- **Verify, don't assert.** When you make a change, build it and (where applicable) run it. "Should work" is not done.
- **Flag scope creep.** If you notice something worth fixing that's outside the current task, mention it — don't silently bundle it.
- **No emoji in code or commits** unless explicitly requested.
- **No new Markdown docs** unless the user asks. Code and inline doc comments are preferred.

---

## 9. Performance & footprint

This is a daemon that runs all day on a laptop. Treat CPU and RAM as scarce.

- Idle CPU should be effectively 0%. If you find yourself adding a `Timer`, justify it.
- Stream large files (`URLSession.uploadTask(with:fromFile:)`); don't `Data(contentsOf:)` an mp3.
- Cancel in-flight `URLSessionTask`s when the user changes settings or quits.
- The menu bar UI re-renders on `@Published` changes — batch state updates so the icon doesn't flicker.

---

## 10. When in doubt

1. Re-read the PRD ([`slides.html`](../slides.html)) and the implementation plan ([`implementation-plan.md`](./implementation-plan.md)).
2. If still unclear, ask the user.
3. If the user is unavailable, pick the option that is **easier to reverse** and note the assumption in the PR description.
