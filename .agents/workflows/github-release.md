---
description: How to deploy and release NoCornyTracer to GitHub
---
# Releasing NoCornyTracer

This workflow explains how to build a new DMG release, update the Sparkle `appcast.xml`, push the changes to GitHub, and deploy the new version via the GitHub CLI.

### 0. Update Changelog
Before any release, ensure you have documented all changes in `CHANGELOG.md`.

### 1. Build and Package
**Mandatory: Always run `./scripts/release.sh` instead of `./scripts/build_dmg.sh` for official releases.**
`release.sh` automatically calls `build_dmg.sh` and then updates `appcast.xml` with the new version details (including the Ed25519 signature and binary length) which is required for Sparkle updates to work.

```bash
./scripts/release.sh
```

### 2. Commit and Push
Next, commit the updated code and `appcast.xml` to the repository.
```bash
git add -A
git commit -m "Bump version to vX.X.X"
git push origin main
```

### 3. Create or Update GitHub Release
Use the GitHub CLI (`gh`) to create the release and attach the DMG. The Personal Access Token is needed for authentication since Git is using a different user globally.

Replace `vX.X.X` with the current target version.

**To create a brand new release:**
Ensure you are logged in to the GitHub CLI with `gh auth login`.
```bash
// turbo
gh release create vX.X.X "dist/NoCornyTracer-X.X.X.dmg" --title "NoCornyTracer vX.X.X" --notes "Release notes go here." --repo Maksym-nocorny/NoCorny-Tracer
```

**To update/overwrite the DMG file on an existing release:**
```bash
// turbo
gh release upload vX.X.X "dist/NoCornyTracer-X.X.X.dmg" --repo Maksym-nocorny/NoCorny-Tracer --clobber
```

## Troubleshooting

### Sparkle "Update Error!"
If the app says "Update Error!" or "You're up to date!" while a new release exists:
1. **Check `appcast.xml`:** Ensure the new version entry exists at the **bottom** (the script appends there).
2. **CDN Propagation:** GitHub Releases can take a few minutes for the download URL to be globally available.
3. **App Cache:** Sometimes Sparkle caches the old `appcast.xml`. Restarting the app usually fixes this.
4. **Incorrect Script:** If you only ran `scripts/build_dmg.sh`, the appcast will be missing the new version entry. You **must** run `scripts/release.sh`.

### Important System Constraints (Bundle IDs & App Name)
To fix a severe macOS 26 Tahoe bug where the system would permanently hide the menu bar icon after repeated developer reinstallations, the app's fundamental definitions were updated in v3.0.0. **Do not change these values casually**, as doing so will cause Sparkle to permanently silently block all auto-updates to your users for security reasons (`SUInvalidHostBundleIdentifierError`).

- **Exact App Name**: `"NoCorny Tracer"` (with a space).
- **Exact Bundle ID**: `com.nocorny.tracer` (changed from `.mac` and `.app`).
- **File Hierarchy Constraints**: Sparkle demands that the downloaded App Name, the Bundle ID, and the Ed25519 signature perfectly align with the currently running application, or it will refuse to install the update to protect against hijacking.
