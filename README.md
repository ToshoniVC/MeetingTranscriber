# MeetingTranscriber

The repository for **Jot** — a native macOS menu-bar utility that watches a folder for Audio Hijack recordings and transcribes them via a user-configured OpenAI-compatible API endpoint. Spec lives in [`PRD/`](PRD/); phased build plan in [`Claude/implementation-plan.md`](Claude/implementation-plan.md); contributor brief in [`CLAUDE.md`](CLAUDE.md).

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
