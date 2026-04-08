---
description: How to run or build test versions of NoCorny Tracer with a different bundle identifier
---
# Testing Workflow

To prevent conflicts with the production version of NoCorny Tracer installed on your system (e.g., Sparkle auto-updates or TCC permissions), you should use a temporary Bundle Identifier for local development and testing.

## 1. Changing the Bundle Identifier

The primary Bundle ID is `com.nocornytracer.mac.v3`. For testing, change it to something like `com.nocornytracer.mac.test`.

### Step A: Update `Info.plist`
Modify `Sources/NoCornyTracer/Info.plist`:
```xml
<key>CFBundleIdentifier</key>
<string>com.nocornytracer.mac.test</string>
```

### Step B: Update `build_dmg.sh` (If creating a test DMG)
If you are running the build script, update the `BUNDLE_ID` variable:
```bash
BUNDLE_ID="com.nocornytracer.mac.test"
```

---

## 2. Running the App

### Running via Terminal
You can run the app directly using `swift run`:
```bash
swift run NoCornyTracer
```
*Note: This will use the temporary Bundle ID if you modified `Info.plist`.*

### Building a Test DMG
If you want to test the full installer and installation flow:
```bash
./scripts/build_dmg.sh
```
*Note: Ensure you changed the `BUNDLE_ID` in `scripts/build_dmg.sh` first.*

---

## 3. Reverting Before Release

> [!IMPORTANT]
> **NEVER RELEASE WITH A TEST BUNDLE ID.**
> Sparkle auto-updates will permanently break for your users if the Bundle ID changes inconsistently.

Before running `./scripts/release.sh` for an official update, ensure you have:
1.  Reverted `Info.plist` back to `com.nocornytracer.mac.v3`.
2.  Reverted `scripts/build_dmg.sh` back to `com.nocornytracer.mac.v3`.

---

## 4. Troubleshooting TCC Permissions
If you change the Bundle ID, macOS will treat the app as a new application. You will need to re-grant:
- Screen Recording
- Camera
- Microphone
- Accessibility

This is the expected behavior and helps test the **Permissions Window** in the app.
