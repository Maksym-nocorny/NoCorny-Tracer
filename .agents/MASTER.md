# AI Agent Instructions — NoCorny Tracer

You are working on **NoCorny Tracer**, a macOS menu bar app for screen + face-cam recording with Dropbox sync and AI-powered file naming.

---

## BEFORE doing any work

Read these files in order:

1. `docs/PUBLISHING.md` — build, versioning, and release process
2. `CHANGELOG.md` — current version and release history

---

## Core rules

### Versioning & Changelog
- **Always bump the version** in `Sources/NoCornyTracer/Info.plist` (`CFBundleShortVersionString` AND `CFBundleVersion`) before building a DMG.
- **Always add a CHANGELOG entry** at the top of `CHANGELOG.md` matching the new version and today's date (`YYYY-MM-DD`).
- Follow the existing changelog format: `## [X.X.X] - YYYY-MM-DD` with `### Added / Fixed / Changed / Important` sections.
- A bundle identifier change is a **BREAKING CHANGE** — bump the minor version (e.g. 3.1.x → 3.2.0) and document it under `### Important`.

### GitHub CLI
- `gh` is not in the default PATH. Always use the full path: `/opt/homebrew/bin/gh`
- Example: `/opt/homebrew/bin/gh pr create ...`, `/opt/homebrew/bin/gh pr merge ...`

### Building
- To build a DMG only: `bash scripts/build_dmg.sh`
- To do a full release (DMG + Sparkle signing + appcast update): `bash scripts/release.sh`
- `Secrets.swift` is gitignored. If missing in a worktree, copy it from the main repo at `Sources/NoCornyTracer/Secrets.swift`.

### Bundle identifier
- Current bundle ID: `com.nocorny.tracer`
- It must be consistent across: `Info.plist`, `scripts/build_dmg.sh`, `LogManager.swift`, `KeychainHelper.swift`, `AudioCaptureManager.swift`, `VideoWriter.swift`, and `docs/PUBLISHING.md`.

### Sparkle auto-updates
- Appcast feed: `https://raw.githubusercontent.com/Maksym-nocorny/NoCorny-Tracer/main/appcast.xml`
- Public key is in `Info.plist` as `SUPublicEDKey` — do not change it unless regenerating the key pair.
- The private key lives in the macOS Keychain and is used by `scripts/release.sh` via Sparkle's `sign_update` tool.
