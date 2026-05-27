# Development Lifecycle

How we build, test, ship, and update Jot when the dev machine and the end-user's Mac are the same Mac.

---

## TL;DR

- **Two installs side-by-side** on the same Mac: `Jot` (Release build, lives in `/Applications`, used for real meetings) and `Jot Dev` (Debug build, runs from Xcode, used for development). Different bundle IDs → totally separate state → they don't interfere with each other.
- **Iteration happens against the Dev build.** Run, test, debug, screenshot. The Release build keeps running normally.
- **Releases ship via Sparkle + GitHub Releases.** Tag a commit on `main` → GitHub Action builds, signs, packages, uploads to a GitHub Release, updates an appcast feed. The Release build sees the new version on next launch and offers a one-click update.
- **Versioning is SemVer.** Pre-1.0 maps cleanly to the four milestones in [`implementation-plan.md`](./implementation-plan.md): `0.1.0` = M1, `0.2.0` = M2, `0.3.0` = M3, `0.4.0` = M4. `1.0.0` = daily-driverable.

---

## 1. The constraint

You have one Mac. It's both the dev machine *and* the only end-user device. The naïve approach — uninstall, rebuild, reinstall every iteration — kills your production install (loses Keychain, Login Item registration, audit log history) every time. We need a model where development and production coexist.

---

## 2. The model: two installs

The same Xcode project produces two distinct app bundles via **build configurations**.

| | Production | Development |
|---|------------|-------------|
| Build configuration | `Release` | `Debug` |
| Bundle identifier | `com.toshonivc.jot` | `com.toshonivc.jot.dev` |
| Display name | `Jot` | `Jot Dev` |
| Menu-bar icon | Standard | Tinted (e.g., orange dot variant) |
| Lives at | `/Applications/Jot.app` | `~/Library/Developer/Xcode/DerivedData/.../Jot.app` |
| Launched by | Login Item (Sparkle-updated copy) | `⌘R` in Xcode |
| Keychain entry | `com.toshonivc.jot` | `com.toshonivc.jot.dev` |
| App Support folder | `~/Library/Application Support/Jot/` | `~/Library/Application Support/Jot Dev/` |
| Watches | Your real Watch Folder | A separate `~/Jot-Dev-Watch/` (set in Dev's Settings) |
| Sparkle | Enabled, points at prod appcast | Disabled (you `⌘R` to update) |

**How it's wired in Xcode:**

- Two `.xcconfig` files at the project root — `Debug.xcconfig` and `Release.xcconfig` — that set `PRODUCT_BUNDLE_IDENTIFIER`, `PRODUCT_NAME`, `MARKETING_VERSION`, and `CURRENT_PROJECT_VERSION`.
- An asset catalog with a `Debug`-suffixed icon variant chosen at build time via `ASSETCATALOG_COMPILER_APPICON_NAME`.
- One Xcode scheme, configurable per-action: Run uses Debug, Archive uses Release.

Because the two apps have different bundle IDs, macOS treats them as wholly separate apps: separate sandboxes, separate Keychains, separate Login Items, separate preferences. You can have both running in the menu bar simultaneously — production icon next to "Dev" icon — and switch between them.

---

## 3. Day-in-the-life workflows

### Building a feature (e.g., Phase 1 — Settings tab)

1. `git checkout -b m1-settings-tab` (per coding-instructions §4 — branch per milestone).
2. Open the project in Xcode. Make changes.
3. `⌘R` — launches **Jot Dev** in the menu bar. Production Jot keeps running.
4. Test the change interactively. Point Dev's Settings at `~/Jot-Dev-Watch/` so it doesn't compete with production for real recordings.
5. `⌘U` — runs the full XCTest suite. Must be green before opening a PR (coding-instructions §6).
6. Stop the Dev app (Xcode's stop button). Production Jot is untouched.
7. Push branch, open PR in VS Code's GitHub PR sidebar.
8. After review and merge to `main`: the change is in the codebase but **not yet on your Mac** in the Release build. To get it there, cut a release (next section).

### Cutting a release

Releases are tag-driven. The flow:

1. On `main`, decide the version per §5 below. Example: M2 is done, bump from `0.1.3` to `0.2.0`.
2. Update `MARKETING_VERSION` in `Release.xcconfig` and commit (`Bump version to 0.2.0`).
3. Tag and push: `git tag v0.2.0 && git push origin v0.2.0`.
4. **GitHub Action takes over** (see §4.4):
   - Builds the Release config.
   - Signs the bundle (ad-hoc, Developer ID, or whatever tier you've set up — see §4.5).
   - Packages as `Jot-0.2.0.zip`.
   - Creates a GitHub Release for the tag with the zip attached.
   - Generates a new `appcast.xml` entry pointing at the release asset, signed with the Sparkle EdDSA key.
   - Commits the updated `appcast.xml` back to `main`.
5. Done. Production Jot on your Mac will see the new version next time it polls Sparkle (on launch + once every 24h).

### End-user installing an update (you, opening Jot tomorrow)

1. Production Jot launches as usual via Login Item.
2. On startup, Sparkle hits the appcast URL.
3. Sees `0.2.0` > current `0.1.3`, signature verifies. Shows a small modal: *"Jot 0.2.0 is available. [Install Update] [Skip] [Remind Me Later]"*.
4. Click **Install Update**. Sparkle downloads, verifies the EdDSA signature, replaces `Jot.app` atomically, relaunches.
5. New version is running. Settings, Keychain entries, Audit Log history, Login Item registration — all preserved across the swap.

### When you need to roll back

You don't roll Sparkle back; you publish a hotfix. If `0.2.0` broke something:

1. Fix on a branch, merge, tag `v0.2.1`.
2. Same release flow as above.
3. Your production app picks up `0.2.1` automatically.

If the bug is catastrophic (app won't launch) and you can't get to the Update prompt: download `Jot-0.1.3.zip` manually from the previous GitHub Release, unzip, drag into `/Applications` replacing the broken bundle. Sparkle will then offer `0.2.1` once it can launch.

---

## 4. The tooling stack

### 4.1 Xcode build configurations

Standard Xcode feature. Two configs (`Debug`, `Release`) per target. Driven by `.xcconfig` files committed to the repo at `Jot/Config/Debug.xcconfig` and `Jot/Config/Release.xcconfig`. The xcconfig pattern keeps these settings in plain text (diffable, reviewable) rather than buried in the binary `project.pbxproj`.

### 4.2 [Sparkle](https://sparkle-project.org)

The de-facto framework for self-updating macOS apps outside the App Store. Added via Swift Package Manager (`https://github.com/sparkle-project/Sparkle`).

What it gives us:
- An `SPUStandardUpdaterController` you instantiate once in `JotApp.swift`.
- A built-in "update available" modal — no UI to write.
- EdDSA signature verification of every downloaded update. **This is what makes auto-update safe even without Apple notarization**: a thief who hijacked GitHub Releases still couldn't push a malicious update because they don't have the EdDSA private key.
- Background polling (interval configurable, default 24h).
- A `Check for Updates…` menu item we can wire into the Settings tab.

Configuration in `Info.plist`:
- `SUFeedURL` → URL of the appcast XML.
- `SUPublicEDKey` → public half of the EdDSA pair (generated once via Sparkle's `generate_keys` tool).
- `SUEnableInstallerLauncherService` → `YES`.

The **private** half of the EdDSA key lives in a GitHub Actions secret (`SPARKLE_PRIVATE_KEY`), never in the repo.

### 4.3 GitHub Releases (hosting)

One Release per tag. Each Release has the `Jot-X.Y.Z.zip` attached. The appcast feed points at these asset URLs. GitHub Releases are free, have no bandwidth limits at our scale, and don't require us to run any infrastructure.

### 4.4 GitHub Actions (CI/CD)

Two workflows under `.github/workflows/`:

**`tests.yml`** — triggers on every push and PR. Runs `xcodebuild test -scheme Jot -destination 'platform=macOS'`. Must be green before PR can merge (branch protection rule on `main`).

**`release.yml`** — triggers on tags matching `v*`. Steps:
1. Checkout, set up Xcode.
2. Import the Developer ID certificate from a secret (if we have one — otherwise skip).
3. `xcodebuild archive` with the Release configuration.
4. Export the `.app` from the archive.
5. (Optional) Submit to Apple Notary Service and staple.
6. Run Sparkle's `sign_update` against `Jot-X.Y.Z.zip` using `SPARKLE_PRIVATE_KEY`.
7. Use `gh release create v$VERSION` to make the GitHub Release and upload the zip.
8. Regenerate `appcast.xml` (Sparkle ships a `generate_appcast` tool that scans a folder of releases).
9. Commit `appcast.xml` back to `main`.

The full release is hands-off after `git push origin v0.2.0`.

### 4.5 Code signing — three tiers

| Tier | Cost | UX | Notes |
|------|------|-----|------|
| **Ad-hoc** (default until shared) | Free | First launch needs right-click → Open. Gatekeeper warns ("Jot cannot be opened because Apple cannot check it for malicious software"). | Set automatically by `xcodebuild` when no signing identity is configured. Sparkle updates still verify safely via EdDSA. |
| **Self-signed** | Free | Same Gatekeeper friction as ad-hoc. | Slightly less common; not recommended over ad-hoc for this use case. |
| **Developer ID + notarization** | $99/year (Apple Developer Program) | Zero friction. App opens with no warning. | Needed only if you share Jot with anyone else. Strongly worth it then. |

**Recommendation:** start ad-hoc. The "Open Anyway" dance happens exactly once per install (twice per Mac total: production install + first-ever Dev launch). When/if you ever want a friend to try Jot, upgrade to Developer ID. The architecture above accommodates either without changes — only the CI signing step differs.

---

## 5. Versioning

### 5.1 Scheme — SemVer with milestone mapping

`MAJOR.MINOR.PATCH`.

| Range | Meaning |
|-------|---------|
| `0.1.x` | M1 complete: app shell + Settings tab + Keychain. Bug fixes within M1 bump PATCH. |
| `0.2.x` | M2 complete: headless end-to-end pipeline. |
| `0.3.x` | M3 complete: full main window with Audit Log + Transcripts tabs live. |
| `0.4.x` | M4 complete: hotkey + autostart + sandboxed. |
| `1.0.0` | First version where everything in the PRD works on a fresh-machine install. |
| `≥ 1.x.x` | Standard SemVer. MAJOR for breaking changes to settings/state on disk, MINOR for features, PATCH for fixes. |

Pre-release suffixes for testing: `0.3.0-beta.1`, `0.3.0-rc.1`. Use sparingly — for a single-user app these mostly add ceremony.

### 5.2 Two version fields in `Info.plist`

macOS apps confusingly carry **two** version numbers:

| Key | xcconfig variable | Type | Example | Purpose |
|---|---|---|---|---|
| `CFBundleShortVersionString` | `MARKETING_VERSION` | SemVer string | `0.2.0` | User-visible version. Shows up in About box, Settings, Sparkle dialogs. |
| `CFBundleVersion` | `CURRENT_PROJECT_VERSION` | Monotonic integer | `42` | Build number. **Sparkle uses this** to compare which version is newer. Must strictly increase between any two updates. |

**Rule:** `MARKETING_VERSION` is set by hand at release time. `CURRENT_PROJECT_VERSION` is computed in CI as `git rev-list --count main` (commit count on main) — guaranteed monotonic, zero thought required.

### 5.3 Git tag format

`vMAJOR.MINOR.PATCH` — e.g., `v0.2.0`, `v1.4.2`, `v0.3.0-beta.1`. The leading `v` is convention; the release workflow regex is `v*`.

### 5.4 Where each number lives

| Place | Source |
|-------|--------|
| `Release.xcconfig` → `MARKETING_VERSION = 0.2.0` | Hand-edited at release time |
| `Release.xcconfig` → `CURRENT_PROJECT_VERSION = $(GIT_COMMIT_COUNT)` | Resolved at build time by a build phase script |
| Git tag `v0.2.0` | `git tag v0.2.0` at release time |
| `appcast.xml` entry | Generated by `generate_appcast` from the zip + tag |
| GitHub Release title | Auto from tag |

---

## 6. State migrations

When `AppSettings` or `AuditLogEntry` shapes change between versions, the new app must read the user's old data. We never wipe state on update.

**Strategy:**
- Every persistent `Codable` model carries a `schemaVersion: Int` field (default `1`).
- Custom `init(from decoder:)` reads `schemaVersion`, dispatches to a per-version decoder.
- One-way migrations only — once you ship `schemaVersion = 2`, you cannot downgrade. (Sparkle won't downgrade either, so this matches reality.)
- Migration code stays in the feature folder that owns the type (e.g., `Features/AuditLog/AuditLogEntry.swift`).
- **Tested as integration tests**: for every schema version we've ever shipped, round-trip a sample payload through the current decoder and assert the result.

If we ever ship something that genuinely needs a clean wipe (rare), the migration code prompts the user — never silent data loss.

---

## 7. Implications for the implementation plan

A few additions are needed in [`implementation-plan.md`](./implementation-plan.md) to make this lifecycle real:

- **Phase 0 (Scaffolding)** also creates `Config/Debug.xcconfig` + `Config/Release.xcconfig`, the dual-bundle-ID setup, and the tinted Dev icon variant. Both apps install/run on day one.
- **Phase 8 (Hardening)** also adds Sparkle as an SPM dependency, wires `SPUStandardUpdaterController` in `JotApp.swift`, generates the EdDSA key pair, commits the public key to `Info.plist`, and stores the private key as a GitHub Actions secret.
- **New Phase 9 (Distribution)** — currently implicit; promote it to a real phase: `tests.yml` and `release.yml` workflows, the `appcast.xml`, a README section for the manual one-time production install (download v0.1.0 zip → drag to `/Applications` → grant Accessibility → done).

I'll add these to the plan in a follow-up edit (separate from this doc) unless you'd rather inline them now.

---

## 8. Open decisions (defaults documented above)

These all have a default. They're listed here so future-you remembers what was chosen and why.

| Decision | Default | When to revisit |
|----------|---------|-----------------|
| Code signing tier | Ad-hoc | When sharing the app with anyone else → upgrade to Developer ID + notarization |
| Repo visibility | Private | If you want a public appcast URL accessible without auth, either flip the repo to public or host `appcast.xml` on a separate public GitHub Pages site |
| Update check cadence | 24h + on launch | If users complain updates are slow to land |
| Beta channel | None (single appcast feed) | If a second tester comes onboard and wants pre-releases |
| Pre-1.0 cadence | Tag a release at the end of each milestone | If iterations within a milestone produce demoable changes worth shipping mid-stream |
| Distribution format | `.zip` (Sparkle's preferred) | If you want a fancier first-install experience → switch to `.dmg` |

---

## 9. Why this is the right shape

A few alternatives we're explicitly *not* doing, with the reason:

- **No "just rebuild and reinstall" loop.** It loses Keychain, Login Item registration, and audit log history every time. Two-install model preserves all of that for the production copy.
- **No App Store distribution.** App Store requires Apple Developer Program, sandboxed restrictions we'd have to relax (or special entitlements we'd have to justify), a review process that adds days per release, and 30% on any future paid version. Sparkle is the standard answer for utilities like this — used by Transmission, Bartender, Rectangle, Lungo, hundreds of others.
- **No custom update server.** GitHub Releases already does this. Self-hosting means we'd maintain auth, uptime, and bandwidth for zero added value at our scale.
- **No `pkg` / `installer` flow.** A drag-to-`/Applications` zip is the right install experience for a menu-bar utility. Installer pkgs need extra signing certs and add user friction.
