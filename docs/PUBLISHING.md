# Publishing & Auto-Updates Guide (NoCorny Tracer)

This document describes the complete process of building, signing, and releasing a new version of NoCorny Tracer to GitHub with Sparkle auto-updates.

---

## 🏗️ 1. Versioning & Changelog

Before building, you must determine the new version number and document the changes.

### Step A: Update `Info.plist`
Open `Sources/NoCornyTracer/Info.plist` and update the version string:
- `CFBundleShortVersionString`: The user-facing version (e.g., `3.2.0`).
- `CFBundleVersion`: The build number (usually same as version for simplicity).

### Step B: Update `CHANGELOG.md`
Add a new entry at the top of `CHANGELOG.md` following the [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format:
```markdown
## [X.X.X] - YYYY-MM-DD
### Added
- Feature description
### Fixed
- Bug fix description
```

---

## 📦 2. Build & Sparkle Signing

The project uses a unified release script that handles both building the application and preparing the Sparkle update feed.

### Run the Release Script
Execute the following command in the project root:
```bash
bash scripts/release.sh
```
> [!TIP]
> Run `bash scripts/release.sh --publish` to have the script create the GitHub release **and** push `appcast.xml` for you in the correct (asset-first) order.

**What this script does:**
1.  **Builds the App**: Runs `swift build -c release` (universal arm64 + x86_64).
2.  **Packages DMG**: Creates a branded DMG installer in the `dist/` folder.
3.  **Signs for Sparkle**: Generates an Ed25519 signature using your private key (stored in macOS Keychain).
4.  **Updates `appcast.xml`**: Automatically adds a new `<item>` to the top of the Sparkle feed with the new version, signature, and download URL. Re-running for a version already present in the feed is a **no-op** (it prints "already has an item … skipping insert") so the script is safe to re-run.

> [!IMPORTANT]
> To sign successfully, your Ed25519 private key must be available in your macOS Keychain. If missing, Sparkle's `sign_update` tool will fail.

---

## 🔏 2b. Code Signing & Notarization (REQUIRED for distribution)

The build produces one of three signing modes. **Only the notarized Developer ID mode is distributable** — the other two are Gatekeeper-blocked on every Mac except the build host.

| Mode | Trigger | Distributable? |
|------|---------|----------------|
| **Ad-hoc** | no signing identity found (local/dev) | ❌ blocked on other Macs |
| **Self-signed** (`NoCornyTracer Dev`) | that identity in keychain, `NOTARIZE` unset | ❌ blocked on other Macs |
| **Developer ID + notarized** | `NOTARIZE=1` + a `Developer ID Application` cert | ✅ accepted everywhere |

When a build is not notarized, `build_dmg.sh` prints a prominent **"DMG is NOT NOTARIZED"** warning. Do not ship that DMG.

### One-time setup (per maintainer machine)
1. **Developer ID Application certificate** — in your Apple Developer account create/download a *Developer ID Application* certificate and import it into the login keychain. Confirm it is present:
   ```bash
   security find-identity -p codesigning | grep "Developer ID Application"
   ```
2. **notarytool keychain profile** — store your Apple credentials once so they don't need to be passed on every build. Use an [app-specific password](https://support.apple.com/en-us/HT204397):
   ```bash
   xcrun notarytool store-credentials "NoCornyTracerNotary" \
     --apple-id "you@example.com" \
     --team-id "TEAMID" \
     --password "app-specific-password"
   ```

### Producing a distributable (notarized) build
Pass the opt-in env vars to either `release.sh` or `build_dmg.sh`:
```bash
NOTARIZE=1 \
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="NoCornyTracerNotary" \
bash scripts/release.sh
```
Instead of a profile you can pass an Apple ID directly: `AC_USERNAME`, `AC_PASSWORD` (app-specific), and `AC_TEAM_ID`.

**What `NOTARIZE=1` adds:**
- Signs the `.app` and **all nested Sparkle code** (frameworks, `Autoupdate`, `Updater.app`, and the `Downloader.xpc` / `Installer.xpc` services) with the **hardened runtime** (`--options runtime --timestamp`), inside-out (helpers first, `.app` last).
- Submits the DMG via `xcrun notarytool submit … --wait`, then `xcrun stapler staple` + `stapler validate` so the DMG launches offline on any Mac.

> [!NOTE]
> The app's four entitlements (audio-input, camera, network.client, files.user-selected) are all compatible with the hardened runtime, so no `com.apple.security.cs.*` exceptions are needed.

> [!WARNING]
> **Sparkle cut-over:** moving installs from ad-hoc to Developer ID is a one-time signing-authority change. Sparkle validates the new app's signature lineage against the running app, so test the update path (install a prior version → Check for Updates → confirm it installs without a signature-authority rejection) on the first notarized release.

### Verifying a notarized build
```bash
codesign --verify --deep --strict --verbose=2 "dist/NoCorny Tracer.app"
codesign -dvvv "dist/NoCorny Tracer.app"          # Authority=Developer ID Application, flags=…runtime
spctl -a -vvv -t install "dist/NoCornyTracer-X.X.X.dmg"   # accepted, source=Notarized Developer ID
xcrun stapler validate "dist/NoCornyTracer-X.X.X.dmg"     # The validate action worked
```

---

## 🚀 3. Deploying to GitHub

Once the build is complete and `appcast.xml` is updated, you need to create the release **and then** push the changes.

> [!IMPORTANT]
> Always **create the GitHub release (upload the DMG) BEFORE pushing `appcast.xml`**. If the feed is pushed first, Sparkle clients fetch it and download an asset that does not exist yet — a 404. The `raw.githubusercontent.com` cache (~5 min, see Troubleshooting) widens this window, so asset-first ordering is required.

### Step A: Create GitHub Release (uploads the asset)
Use the GitHub CLI (`gh`) or the web interface to create a new release with the DMG attached.

**Via Command Line:**
```bash
gh release create vX.X.X "dist/NoCornyTracer-X.X.X.dmg" \
  --title "vX.X.X" \
  --notes "Documented in CHANGELOG.md"
```

**Manual Upload:**
1. Go to [GitHub Releases](https://github.com/Maksym-nocorny/NoCorny-Tracer/releases/new).
2. Create a new tag (e.g., `v3.2.0`).
3. Upload the `.dmg` file from the `dist/` folder.
4. Publish the release.

### Step B: Commit & Push the feed
Now that the asset is live, sync the repository so users' apps can see the updated `appcast.xml`.
```bash
git add appcast.xml CHANGELOG.md Sources/NoCornyTracer/Info.plist
git commit -m "Release vX.X.X"
git push origin main
```

---

## 🔄 4. How Auto-Updates Work

The application uses the **Sparkle Framework** to check for updates.

1.  **Feed Check**: On startup (or via menu), the app fetches `https://raw.githubusercontent.com/Maksym-nocorny/NoCorny-Tracer/main/appcast.xml`.
2.  **Version Comparison**: It compares its local `CFBundleShortVersionString` with the latest `<sparkle:version>` in the XML.
3.  **Verification**: If a newer version is found, it downloads the DMG. Sparkle verifies the download matches the `sparkle:edSignature` in the feed to prevent tampering.
4.  **Installation**: Sparkle mounts the DMG, extracts the `.app`, and replaces the old version automatically.

### Key Requirements for Success:
- **Bundle ID Link**: The app's Bundle ID (`com.nocorny.tracer`) must match exactly between the running app and the update.
- **Public Key**: The `SUPublicEDKey` in `Info.plist` must match the public counterpart of the private key used by `release.sh`.
- **App Name**: The app name must remain `"NoCorny Tracer"` as defined in the build scripts.

---

## 🛠️ Troubleshooting

- **"Update Error!"**: Usually means the Ed25519 signature in `appcast.xml` is invalid or the Bundle ID has changed inconsistently.
- **"You're up to date" (wrongly)**: Check if GitHub's `raw.githubusercontent.com` cache has propagated the new `appcast.xml` yet (usually takes ~5 mins).
- **DMG Won't Open**: Ensure the app was code-signed (even ad-hoc) during the `build_dmg.sh` phase.
- **"cannot be checked" / "damaged" on another Mac**: The DMG was not notarized. Ad-hoc and self-signed builds are Gatekeeper-blocked everywhere except the build host — rebuild with `NOTARIZE=1` + a Developer ID cert (see §2b "Code Signing & Notarization").
