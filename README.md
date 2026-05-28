# MeetingTranscriber

The repository for **Jot** — a native macOS menu-bar utility that watches a folder for Audio Hijack recordings and transcribes them via a user-configured OpenAI-compatible API endpoint. Spec lives in [`PRD/`](PRD/); phased build plan in [`Claude/implementation-plan.md`](Claude/implementation-plan.md); contributor brief in [`CLAUDE.md`](CLAUDE.md).

## Using Jot

### What you need

- macOS 14 Sonoma or newer.
- **Audio Hijack 4** from Rogue Amoeba — Jot doesn't record on its own; it tells AH to start/stop a session you've configured. Install it from [rogueamoeba.com/audiohijack](https://rogueamoeba.com/audiohijack/) and **move it into `/Applications/`** (running from `~/Downloads/` prevents its Shortcuts actions from appearing).
- An OpenAI-compatible `/audio/transcriptions` endpoint and API key (Groq, OpenAI, self-hosted Whisper, …).

### First-run setup

1. **Settings → API**: paste your Base URL (e.g. `https://api.groq.com/openai/v1/audio/transcriptions`), Model String (e.g. `whisper-large-v3`), and API Key. Click **Test connection**. The key is stored in your macOS Keychain, never on disk in plaintext.
2. **Settings → Folders**: pick a **Watch Folder** (where Audio Hijack saves recordings) and an **Output Folder** (where Jot files transcripts). Permissions on these are remembered across relaunches via security-scoped bookmarks.
3. **Settings → Recording shortcut**:
   - Record a global hotkey.
   - Expand the per-field **How to** disclosures and create the two Shortcuts (`Jot Start Recording` + `Jot Stop Recording`) using AH4's **Run/Stop Session** action. Launch Audio Hijack first — Shortcuts won't surface the action until AH has been opened at least once.
4. **Settings → System**: optionally flip **Launch on Startup** on so Jot reappears after reboot.

### Daily use

- Press your hotkey from any app → Jot pops a meeting-name prompt → Audio Hijack starts recording → the menu-bar icon turns into a red pulsing dot.
- Press the hotkey again to stop. Audio Hijack writes the file into your Watch Folder; Jot picks it up, transcribes it, and moves the audio + transcript into a meeting folder under your Output Folder.
- Open the main window from the menu-bar icon → **Transcripts** tab shows every meeting folder newest-first; right-click a row for **Reveal in Finder / Rename / Move to Trash**.
- The **Audit Log** tab records every pipeline event. Failure rows surface a **Details** button (opens an inspector modal with the full message + Copy details) and a **Retry** button (re-runs transcription on the same file, which stays in the Watch Folder until it succeeds).

### Logs & troubleshooting

- The menu-bar dropdown has a **Developer** submenu with a **Verbose logging** toggle. When ON, it reveals **Open Console.app** + **Copy 'log show' command** affordances. Paste the copied command into Terminal to stream the last 30 minutes of Jot's `os.Logger` output.
- Raw command for the curious:
  ```bash
  log show --predicate 'subsystem == "com.toshonivc.jot"' --info --debug --last 30m
  ```
- `Jot Dev` (Debug) and `Jot` (Release) keep totally separate logs, settings, and Keychain entries — see the [Two-install model](#two-install-model) section.

### Common gotchas

- **"Run/Stop Session" doesn't appear in Shortcuts.** Audio Hijack must be installed in `/Applications/` (not Downloads, not Desktop) and launched at least once this session. Quit and re-open Shortcuts if it still doesn't show.
- **Hotkey does nothing.** Carbon `RegisterEventHotKey` may need Accessibility permission on first use. The Settings tab surfaces a registration error inline if so — click it to jump into System Settings → Privacy & Security → Accessibility and toggle Jot on.
- **Watch Folder doesn't pick up new files.** Confirm the file extension (`.mp3`, `.m4a`, `.wav`) and that Audio Hijack actually wrote it there — partial writes (`.tmp`, `.partial`) are deliberately ignored until they settle.
- **Settings won't save the folder I pick.** Under App Sandbox you must use the **Choose…** picker — typing a path manually doesn't grant access. Reset by clicking Choose… again.

---

## Development

The Xcode project (`Jot.xcodeproj`) is generated from [`project.yml`](project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen). The generated project file is committed for ease of clone-and-build, but `project.yml` is the source of truth — if you change build settings in Xcode UI, also update `project.yml` and regenerate or your changes will be lost.

### First-time setup

```bash
# Verify Xcode 15+ is installed and licensed
xcodebuild -version

# Install XcodeGen (one of):
brew install xcodegen                                              # Homebrew
# or build from source (no Homebrew needed):
git clone https://github.com/yonaskolb/XcodeGen.git ~/tools/XcodeGen
cd ~/tools/XcodeGen && swift build -c release
```

### Iteration loop

```bash
open Jot.xcodeproj                                                 # then ⌘R to run, ⌘U to test
# or from the CLI:
xcodebuild -project Jot.xcodeproj -scheme Jot -destination 'platform=macOS' test
xcodebuild -project Jot.xcodeproj -scheme Jot -configuration Release build
```

### After editing `project.yml`

```bash
~/tools/XcodeGen/.build/release/xcodegen generate   # or just `xcodegen generate` if brew-installed
```

### Two-install model

- **`Jot Dev.app`** — Debug build, bundle `com.toshonivc.jot.dev`, 🔨 hammer icon in menu bar. Runs via Xcode `⌘R` for development. Separate Keychain + preferences + Application Support folder from the production build.
- **`Jot.app`** — Release build, bundle `com.toshonivc.jot`, waveform icon. The production install (post-Phase 9 it'll be auto-distributed via Sparkle + GitHub Releases).

Both can run side-by-side in the menu bar. See [`Claude/development-lifecycle.md`](Claude/development-lifecycle.md) for the full lifecycle and versioning model.
