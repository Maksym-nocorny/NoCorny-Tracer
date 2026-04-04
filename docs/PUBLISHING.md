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
./release.sh
```

**What this script does:**
1.  **Builds the App**: Runs `swift build -c release`.
2.  **Packages DMG**: Creates a branded DMG installer in the `dist/` folder.
3.  **Signs for Sparkle**: Generates an Ed25519 signature using your private key (stored in macOS Keychain).
4.  **Updates `appcast.xml`**: Automatically adds a new `<item>` to the top of the Sparkle feed with the new version, signature, and download URL.

> [!IMPORTANT]
> To sign successfully, your Ed25519 private key must be available in your macOS Keychain. If missing, Sparkle's `sign_update` tool will fail.

---

## 🚀 3. Deploying to GitHub

Once the build is complete and `appcast.xml` is updated, you need to push the changes and create the release.

### Step A: Commit & Push
Sync the repository so users' apps can see the updated `appcast.xml`.
```bash
git add appcast.xml CHANGELOG.md Sources/NoCornyTracer/Info.plist
git commit -m "Release vX.X.X"
git push origin main
```

### Step B: Create GitHub Release
Use the GitHub CLI (`gh`) or the web interface to create a new release.

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
