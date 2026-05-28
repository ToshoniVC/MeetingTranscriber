# Changelog

Versions are tagged from `main` (`v0.1.0`, `v0.1.1`, …) and built/signed by
`.github/workflows/release.yml`. The user-visible Sparkle dialog reads its
release notes from the `<description>` element in `docs/appcast.xml`, not
this file — this is the long-form humans-only log.

## v0.1.5 — Sparkle round-trip smoke test

End-to-end verification that an auto-update lands cleanly through the in-app
**Settings → Check for Updates…** flow now that the `-spki` entitlement is in
place (v0.1.4). No code changes.

## v0.1.4 — Sparkle Installer Interaction entitlement

Added the missing `$(PRODUCT_BUNDLE_IDENTIFIER)-spki` mach-lookup
allow-list entry. Together with `-spks` (Status) and `-spkp` (Progress)
added in v0.1.2, the sandboxed main app can now talk to all three of
Sparkle's update helper services. v0.1.0 → v0.1.4 had to be installed
manually because earlier builds' entitlements were missing one of the
three names.

## v0.1.2 — First Sparkle entitlements

Added `-spks` + `-spkp` mach-lookup entitlements (turned out `-spki` was
also required — see v0.1.4).

## v0.1.1 — Sandbox-safe Shortcuts invocation + sidebar version footer

- Replaced `/usr/bin/shortcuts` Process spawn with
  `NSWorkspace.open(shortcuts://run-shortcut?name=…&input=…)`. The CLI
  crashed inside our sandbox; URL-scheme invocation hops out of the
  container cleanly.
- Added sidebar version footer with an "Update available: vX.Y" badge
  when Sparkle's background check has found a newer release.

## v0.1.0 — First public release

Initial production build. Hotkey-triggered recording via user-authored
Apple Shortcuts, transcription via OpenAI-compatible API, Audit Log,
Transcripts browser, App Sandbox, ad-hoc signed, auto-update via Sparkle
+ GitHub Pages-hosted appcast.
