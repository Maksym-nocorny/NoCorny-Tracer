#!/bin/bash
set -e

# === Configuration ===
APP_NAME="NoCorny Tracer"
BINARY_NAME="NoCornyTracer"
BUNDLE_ID="com.nocorny.tracer"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Clean up old dist artifacts to prevent cache issues
echo "🧹 Cleaning dist directory..."
mkdir -p "$PROJECT_DIR/dist"
rm -rf "$PROJECT_DIR/dist/"*

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/Sources/NoCornyTracer/Info.plist")
# Resolved after the build via `swift build --show-bin-path` (see Step 1). For a
# multi-arch build SwiftPM emits to .build/apple/Products/Release, NOT .build/release.
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
DMG_DIR="$PROJECT_DIR/dist"
DMG_NAME="NoCornyTracer-$VERSION"
DMG_PATH="$DMG_DIR/$DMG_NAME.dmg"

echo "🔨 Building $APP_NAME v$VERSION..."

# === Step 1: Build release binary ===
cd "$PROJECT_DIR"
# Build a universal (arm64 + x86_64) binary so Intel Macs can run the app.
# IMPORTANT: a multi-arch build uses SwiftPM's Xcode build system, which emits the
# fat binary + resource bundle + Sparkle.framework under .build/apple/Products/Release
# — NOT the single-arch .build/release path. Resolve the real location with
# --show-bin-path so every downstream copy/sign step looks in the right place.
# Info.plist is a link-time input (-sectcreate in Package.swift) that SwiftPM does NOT
# track, so we remove only the cached executable (NOT all of .build — that would wipe
# the Sparkle artifacts and create-dmg cache) to force the sectcreate to re-run.
BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null)"
rm -f "$BUILD_DIR/$BINARY_NAME"
swift build -c release --arch arm64 --arch x86_64 2>&1

echo "✅ Build complete"

# Guard: confirm the executable is actually universal before packaging.
if ! lipo -archs "$BUILD_DIR/$BINARY_NAME" | grep -q x86_64 || \
   ! lipo -archs "$BUILD_DIR/$BINARY_NAME" | grep -q arm64; then
    echo "❌ Built binary is not universal: $(lipo -archs "$BUILD_DIR/$BINARY_NAME")"
    echo "   Expected both arm64 and x86_64 slices."
    exit 1
fi
echo "🧩 Universal binary: $(lipo -archs "$BUILD_DIR/$BINARY_NAME")"

# Guard against a stale sectcreate-embedded Info.plist (Fix 7): decode the
# __TEXT,__info_plist section from the freshly-built binary and confirm its
# CFBundleShortVersionString matches the source Info.plist. otool -X -s emits the
# raw section bytes as hex; we strip offsets/whitespace, hex-decode, and read the key.
EMBEDDED_PLIST=$(otool -X -s __TEXT __info_plist "$BUILD_DIR/$BINARY_NAME" 2>/dev/null \
    | awk '{$1=""; print}' | tr -d ' \t\n' | xxd -r -p 2>/dev/null || true)
if [ -n "$EMBEDDED_PLIST" ]; then
    EMBEDDED_VERSION=$(echo "$EMBEDDED_PLIST" \
        | /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /dev/stdin 2>/dev/null || true)
    if [ -n "$EMBEDDED_VERSION" ] && [ "$EMBEDDED_VERSION" != "$VERSION" ]; then
        echo "❌ Embedded Info.plist is stale: section reports v$EMBEDDED_VERSION but source is v$VERSION."
        echo "   The -sectcreate plist did not re-link. Clean the release binary and rebuild."
        exit 1
    fi
    echo "🔖 Embedded Info.plist version: ${EMBEDDED_VERSION:-unknown} (source v$VERSION)"
fi

# === Step 2: Create .app bundle structure ===
echo "📦 Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy the binary
cp "$BUILD_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy the SPM resource bundle to Contents/Resources and symlink from Contents/MacOS/
# SPM's auto-generated Bundle.module accessor looks in Bundle.main.bundleURL which
# resolves to Contents/MacOS/ for an executable. The symlink bridges the two locations.
if [ -d "$BUILD_DIR/NoCornyTracer_NoCornyTracer.bundle" ]; then
    cp -R "$BUILD_DIR/NoCornyTracer_NoCornyTracer.bundle" "$APP_BUNDLE/Contents/Resources/"
    ln -s "../Resources/NoCornyTracer_NoCornyTracer.bundle" "$APP_BUNDLE/Contents/MacOS/NoCornyTracer_NoCornyTracer.bundle"
fi

# Copy Info.plist
cp "$PROJECT_DIR/Sources/NoCornyTracer/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Embed Frameworks (Sparkle)
echo "📦 Embedding Frameworks..."
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    cp -R "$BUILD_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/"
    if [ -d "$BUILD_DIR/SparkleCore.framework" ]; then
        cp -R "$BUILD_DIR/SparkleCore.framework" "$APP_BUNDLE/Contents/Frameworks/"
    fi
    # Add rpath so the executable can find the frameworks. Do NOT mask a failure here:
    # a missing @rpath produces a perfectly signed, notarized, stapled DMG that then
    # crashes on launch for EVERY user because Sparkle.framework can't be resolved — and
    # notarization will not catch it. Add it idempotently (the bundle is rebuilt each run,
    # but guard anyway) and then assert it is present.
    if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath @executable_path/../Frameworks "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    fi
    if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q '@executable_path/../Frameworks'; then
        echo "❌ @rpath '@executable_path/../Frameworks' missing from the executable after install_name_tool."
        echo "   The app would crash on launch (Sparkle.framework unresolved). Aborting."
        exit 1
    fi
fi

# Add CFBundleExecutable and CFBundleIconFile to Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_BUNDLE/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP_BUNDLE/Contents/Info.plist"

# Create .icns from the app logo if it exists
if [ -f "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" ]; then
    echo "🎨 Creating app icon..."
    ICONSET_DIR="$PROJECT_DIR/dist/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    sips -z 16 16     "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" --out "$ICONSET_DIR/icon_16x16.png"      > /dev/null
    sips -z 32 32     "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" --out "$ICONSET_DIR/icon_16x16@2x.png"   > /dev/null
    sips -z 32 32     "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" --out "$ICONSET_DIR/icon_32x32.png"      > /dev/null
    sips -z 64 64     "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" --out "$ICONSET_DIR/icon_32x32@2x.png"   > /dev/null
    sips -z 128 128   "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" --out "$ICONSET_DIR/icon_128x128.png"    > /dev/null
    sips -z 256 256   "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" --out "$ICONSET_DIR/icon_256x256.png"    > /dev/null
    sips -z 512 512   "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" --out "$ICONSET_DIR/icon_512x512.png"    > /dev/null
    sips -z 1024 1024 "$PROJECT_DIR/assets/NoCorny Tracer Ico.png" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
    echo "✅ App icon created"
fi

# === Step 3: Code sign with self-signed certificate and entitlements ===
echo "🔏 Code signing..."
ENTITLEMENTS="$PROJECT_DIR/Sources/NoCornyTracer/NoCornyTracer.entitlements"
# The signing identity is explicit and overridable. When notarizing it is AUTO-DETECTED
# from the keychain below (the sole "Developer ID Application" identity). An explicit
# SIGN_IDENTITY (SHA-1 hash — preferred — or full name) always wins. There is deliberately
# NO default identity anymore: the old hard-coded "NoCornyTracer Dev" was a footgun — a
# typo'd name (the keychain has "NoCorny Tracer Dev", with a space) that silently fell
# through to ad-hoc signing on a build that thought it was signing for real.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
# A stable designated requirement keyed on the bundle id keeps Sparkle in-place
# updates and TCC grants intact across machines and across both signing paths.
DESIGNATED_REQ="=designated => identifier \"$BUNDLE_ID\""

# --- Notarization opt-in (B8.5) -------------------------------------------------
# Gatekeeper blocks ad-hoc/self-signed apps on machines other than the build host.
# Distribution builds must be (a) signed with a "Developer ID Application" cert under
# the hardened runtime and (b) notarized + stapled. Apple credentials and the cert
# are NOT available in every environment, so this whole path is OPT-IN:
#
#   NOTARIZE=1                      enable the Developer ID + hardened-runtime + notarize flow
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   the Developer ID cert to sign with
#   NOTARY_PROFILE=<name>           a notarytool keychain profile created via
#                                   `xcrun notarytool store-credentials` (preferred), OR
#   AC_USERNAME / AC_PASSWORD / AC_TEAM_ID   an Apple ID + app-specific password + team id
#
# When NOTARIZE is unset, the existing ad-hoc/self-signed path is used unchanged and
# a prominent warning is printed that the DMG is NOT notarized (Gatekeeper-blocked
# elsewhere). NOTARIZE=1 implies hardened-runtime signing; it does not change the
# bundle id or the Sparkle Ed25519 signing key (those are handled in release.sh).
#
# A RELEASE build MUST be notarized — make that structural, not a convention you can
# forget. RELEASE_BUILD=1 (set by release.sh) now implies NOTARIZE=1, so there is no
# way to accidentally ship an ad-hoc/self-signed DMG to the public by leaving an env
# var unset. To build a local, non-notarized copy just omit RELEASE_BUILD.
if [ "${RELEASE_BUILD:-0}" = "1" ]; then
    NOTARIZE=1
fi
NOTARIZE="${NOTARIZE:-0}"
# Under the hardened runtime, codesign also needs --options runtime --timestamp. These
# flags are appended only on the Developer ID path; ad-hoc signing keeps its old args.
HARDENED_FLAGS=(--options runtime --timestamp)

# Resolve the Sparkle framework's versioned directory instead of hard-coding
# "Versions/B" — a Sparkle version bump could change the letter and silently skip
# signing the nested helpers (Fix 10). Prefer the Current symlink, fall back to a glob.
resolve_sparkle_version_dir() {
    local fw="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    if [ -L "$fw/Versions/Current" ]; then
        echo "$fw/Versions/$(readlink "$fw/Versions/Current")"
        return 0
    fi
    local matches=( "$fw"/Versions/[A-Z] )
    if [ "${#matches[@]}" -eq 1 ] && [ -d "${matches[0]}" ]; then
        echo "${matches[0]}"
        return 0
    fi
    return 1
}

# Sign Sparkle's nested code (Autoupdate, Updater.app, XPC services) and the
# frameworks. Failures are surfaced (no 2>/dev/null || true) so a path drift or a
# genuine signing error hard-fails the build under `set -e` instead of shipping a
# subtly-broken DMG (Fix 10). $1 is the codesign identity ("-" for ad-hoc).
#
# When NOTARIZE=1, the extra hardened-runtime flags ($HARDENED_FLAGS) are appended so
# every nested Mach-O is hardened — notarization rejects any unhardened nested code.
# Signing is inside-out: helpers/XPC first, then the framework bundles, then (by the
# caller) the .app last.
sign_frameworks() {
    local identity="$1"
    local -a extra=()
    if [ "$NOTARIZE" = "1" ]; then
        extra=("${HARDENED_FLAGS[@]}")
    fi
    if [ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
        local version_dir
        if ! version_dir=$(resolve_sparkle_version_dir); then
            echo "❌ Could not resolve Sparkle.framework versioned directory (Versions/Current or Versions/[A-Z])"
            exit 1
        fi
        # Sparkle ships XPC services (Downloader.xpc / Installer.xpc) that must be
        # signed (and hardened, when notarizing) or notarization will reject them.
        # Sign them before the helpers/framework that contain them (inside-out).
        if [ -d "$version_dir/XPCServices" ]; then
            local xpc
            for xpc in "$version_dir/XPCServices"/*.xpc; do
                [ -e "$xpc" ] || continue
                codesign --force "${extra[@]}" --sign "$identity" "$xpc"
            done
        fi
        if [ -e "$version_dir/Autoupdate" ]; then
            codesign --force "${extra[@]}" --sign "$identity" "$version_dir/Autoupdate"
        else
            echo "❌ Sparkle Autoupdate not found at $version_dir/Autoupdate"
            exit 1
        fi
        if [ -e "$version_dir/Updater.app" ]; then
            codesign --force "${extra[@]}" --sign "$identity" "$version_dir/Updater.app"
        else
            echo "❌ Sparkle Updater.app not found at $version_dir/Updater.app"
            exit 1
        fi
        codesign --force "${extra[@]}" --sign "$identity" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi
    if [ -d "$APP_BUNDLE/Contents/Frameworks/SparkleCore.framework" ]; then
        codesign --force "${extra[@]}" --sign "$identity" "$APP_BUNDLE/Contents/Frameworks/SparkleCore.framework"
    fi
}

# Resolve the signing identity for the notarized path. Match on the exact SHA-1 HASH
# (column 2 of `security find-identity -v`) — unambiguous, immune to substring/typo bugs,
# and `-v` guarantees we never pick an expired/untrusted cert (plain `find-identity`
# lists those under "Matching identities" and a name-grep would happily select them —
# this machine has two CSSMERR_TP_NOT_TRUSTED self-signed certs). Require EXACTLY ONE
# "Developer ID Application" cert so a multi-cert machine fails loudly instead of guessing.
TEAM_ID=""
if [ "$NOTARIZE" = "1" ] && [ -z "$SIGN_IDENTITY" ]; then
    DEVID_LINES="$(security find-identity -v -p codesigning | grep 'Developer ID Application' || true)"
    DEVID_COUNT="$(printf '%s' "$DEVID_LINES" | grep -c 'Developer ID Application' || true)"
    if [ "${DEVID_COUNT:-0}" -eq 0 ]; then
        echo "❌ No 'Developer ID Application' identity found in the keychain."
        echo "   Create one:  Xcode ▸ Settings ▸ Accounts ▸ (team) ▸ Manage Certificates ▸ + ▸ Developer ID Application"
        echo "   or export SIGN_IDENTITY explicitly (SHA-1 hash preferred)."
        exit 1
    elif [ "$DEVID_COUNT" -gt 1 ]; then
        echo "❌ Multiple 'Developer ID Application' identities found — refusing to guess which to use:"
        printf '%s\n' "$DEVID_LINES"
        echo "   Pick one: export SIGN_IDENTITY='<SHA-1 hash from column 2 above>'."
        exit 1
    fi
    SIGN_IDENTITY="$(printf '%s' "$DEVID_LINES" | awk '{print $2}')"
    echo "🔎 Auto-detected Developer ID identity: $(printf '%s' "$DEVID_LINES" | sed -n 's/.*"\(.*\)".*/\1/p')  [$SIGN_IDENTITY]"
fi

# Opt-in Developer ID + hardened-runtime path (B8.5). Requires NOTARIZE=1 AND a
# "Developer ID Application" identity. Signs inside-out (nested Sparkle helpers/XPC/
# frameworks first, then the .app last) so notarization accepts the bundle. The DMG
# itself is notarized + stapled later (Step 4b).
if [ "$NOTARIZE" = "1" ]; then
    # Look up the resolved identity by its own value (hash OR name) among VALID identities
    # only (-v). This validates existence and lets us confirm it really is a Developer ID
    # Application cert and extract the Team ID, whether SIGN_IDENTITY is a hash or a name.
    IDENTITY_LINE="$(security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY" | head -1 || true)"
    if [ -z "$IDENTITY_LINE" ]; then
        echo "❌ NOTARIZE=1 but signing identity '$SIGN_IDENTITY' is not among the valid codesigning identities."
        echo "   Available Developer ID Application identities:"
        security find-identity -v -p codesigning | grep 'Developer ID Application' || echo "     (none)"
        exit 1
    fi
    case "$IDENTITY_LINE" in
        *"Developer ID Application"*) ;;
        *)
            echo "❌ NOTARIZE=1 requires a 'Developer ID Application' cert for Gatekeeper."
            echo "   Resolved '$SIGN_IDENTITY' → $IDENTITY_LINE"
            echo "   'Apple Development' / 'Apple Distribution' certs are rejected by the notary service."
            exit 1
            ;;
    esac
    TEAM_ID="$(printf '%s' "$IDENTITY_LINE" | sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p')"
    echo "🛡️  Developer ID + hardened-runtime signing (team ${TEAM_ID:-unknown})..."
    sign_frameworks "$SIGN_IDENTITY"
    # The .app is signed LAST, with the hardened runtime + secure timestamp.
    codesign --force "${HARDENED_FLAGS[@]}" --sign "$SIGN_IDENTITY" \
        --requirements "$DESIGNATED_REQ" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
    echo "✅ Code signed (Developer ID, hardened runtime)"
    # Assert it is the right KIND of signature, not merely present: hardened-runtime flag
    # set, and the whole bundle (nested helpers included) verifies strictly.
    if ! codesign -dvvv "$APP_BUNDLE" 2>&1 | grep -q 'flags=.*runtime'; then
        echo "❌ Hardened runtime flag not set on the signed app — notarization would reject it."
        exit 1
    fi
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    echo "✅ Signature verified (hardened runtime, --deep --strict)"
# Check if the (non-notarized) self-signed identity exists. `-n` guards against an empty
# SIGN_IDENTITY (which would make grep match every line); `-v` skips untrusted/expired certs.
elif [ -n "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    sign_frameworks "$SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" --requirements "$DESIGNATED_REQ" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
    echo "✅ Code signed with '$SIGN_IDENTITY' certificate"
    echo "⚠️  NOT NOTARIZED: this DMG will be Gatekeeper-blocked on other Macs."
    echo "    Set NOTARIZE=1 with a 'Developer ID Application' cert to ship a distributable build."
elif [ "${RELEASE_BUILD:-0}" = "1" ]; then
    # Release builds must not silently ad-hoc sign a public distribution.
    echo "❌ Signing identity '$SIGN_IDENTITY' not found, and RELEASE_BUILD=1."
    echo "   Refusing to ad-hoc sign a release. Either:"
    echo "     - import the '$SIGN_IDENTITY' identity, or"
    echo "     - export SIGN_IDENTITY='Developer ID Application: …' pointing at a real cert"
    echo "       (and set NOTARIZE=1 to notarize + staple for distribution)."
    exit 1
else
    # Local/test build: ad-hoc fallback is allowed but loudly marked as non-distributable.
    echo "⚠️  Signing identity '$SIGN_IDENTITY' not found — falling back to ad-hoc signing"
    echo "⚠️  SIGNED MODE: ad-hoc — NOT for distribution"
    sign_frameworks -
    codesign --force --sign - --requirements "$DESIGNATED_REQ" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
    echo "✅ Code signed (ad-hoc) with a stable designated requirement"
    echo "⚠️  NOT NOTARIZED: ad-hoc builds are Gatekeeper-blocked on every Mac except this one."
fi

# === Step 4: Create DMG with drag-to-Applications ===
echo "💿 Creating DMG installer..."

# Clean up old DMG
rm -f "$DMG_PATH"
rm -rf "$DMG_DIR/dmg_staging"

# Create staging directory
STAGING="$DMG_DIR/dmg_staging"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"

# Create the DMG
if ! command -v create-dmg &> /dev/null; then
    echo "⬇️ Downloading create-dmg..."
    # Pinned to create-dmg v1.1.0 — verify the tarball's SHA-256 before extracting
    # and executing it, so a compromised/redirected download can't run arbitrary code.
    CREATE_DMG_URL="https://github.com/create-dmg/create-dmg/archive/refs/tags/v1.1.0.tar.gz"
    CREATE_DMG_SHA256="d50e14a00b73a3f040732b4cfa11361f5786521719059ce2dfcccd9088d3bf32"
    mkdir -p "$PROJECT_DIR/.build/create-dmg-src"
    TARBALL="$PROJECT_DIR/.build/create-dmg-v1.1.0.tar.gz"
    # -sSfL: silent, show errors, fail on HTTP errors (no 0-byte "success"), follow redirects.
    curl -sSfL "$CREATE_DMG_URL" -o "$TARBALL"
    if ! echo "$CREATE_DMG_SHA256  $TARBALL" | shasum -a 256 -c -; then
        echo "❌ create-dmg checksum mismatch — refusing to extract/execute."
        echo "   Expected SHA-256: $CREATE_DMG_SHA256"
        rm -f "$TARBALL"
        exit 1
    fi
    tar -xz -f "$TARBALL" -C "$PROJECT_DIR/.build/create-dmg-src" --strip-components=1
    CREATE_DMG="$PROJECT_DIR/.build/create-dmg-src/create-dmg"
else
    CREATE_DMG="create-dmg"
fi

"$CREATE_DMG" \
  --volname "$APP_NAME" \
  --background "$PROJECT_DIR/assets/background.tiff" \
  --window-pos 200 120 \
  --window-size 512 319 \
  --icon-size 96 \
  --icon "$APP_NAME.app" 128 150 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 384 150 \
  "$DMG_PATH" \
  "$STAGING/"

# Clean up staging
rm -rf "$STAGING"

# === Step 4b: Notarize + staple the DMG (opt-in, B8.5) ===
# Only runs when NOTARIZE=1 (the .app was already Developer-ID + hardened-runtime
# signed in Step 3). Submits the DMG to Apple's notary service, waits for the verdict,
# then staples the ticket so the DMG launches offline on any Mac without a Gatekeeper
# prompt. Credentials come from a notarytool keychain profile (NOTARY_PROFILE,
# preferred) or an Apple ID app-specific password (AC_USERNAME/AC_PASSWORD/AC_TEAM_ID).
if [ "$NOTARIZE" = "1" ]; then
    echo ""
    echo "🍏 Notarizing DMG (this can take several minutes)..."
    # Build the credential args for both notarytool invocations (submit AND log-on-failure)
    # so we can fetch the reject reason without re-typing them.
    NOTARY_CREDS=()
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        NOTARY_CREDS=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -n "${AC_USERNAME:-}" ] && [ -n "${AC_PASSWORD:-}" ] && [ -n "${AC_TEAM_ID:-}" ]; then
        NOTARY_CREDS=(--apple-id "$AC_USERNAME" --password "$AC_PASSWORD" --team-id "$AC_TEAM_ID")
    else
        echo "❌ NOTARIZE=1 but no notary credentials provided."
        echo "   Set NOTARY_PROFILE=<profile> (from 'xcrun notarytool store-credentials'),"
        echo "   or AC_USERNAME + AC_PASSWORD + AC_TEAM_ID (Apple ID app-specific password)."
        echo "   See scripts/setup_signing.sh for the one-time setup."
        exit 1
    fi

    # Capture the submit output so we can pull the submission id and, on rejection, print
    # the notary log — which is the ONLY thing that says WHY Apple rejected the build.
    set +e
    SUBMIT_OUT="$(xcrun notarytool submit "$DMG_PATH" "${NOTARY_CREDS[@]}" --wait 2>&1)"
    SUBMIT_RC=$?
    set -e
    echo "$SUBMIT_OUT"
    SUBMISSION_ID="$(printf '%s\n' "$SUBMIT_OUT" | awk '/[[:space:]]id:/{print $2; exit}')"
    if [ "$SUBMIT_RC" -ne 0 ] || ! printf '%s' "$SUBMIT_OUT" | grep -q 'status: Accepted'; then
        echo "❌ Notarization did not succeed."
        if [ -n "$SUBMISSION_ID" ]; then
            echo "   Fetching the notary log for submission $SUBMISSION_ID:"
            xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_CREDS[@]}" || true
        fi
        exit 1
    fi

    echo "📎 Stapling notarization ticket to the DMG..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    # Prove Gatekeeper's verdict. Do NOT use `spctl -t install "$DMG_PATH"`: we notarize
    # the .app and staple the DMG, but never codesign the DMG *container* itself, so that
    # check reports "no usable signature" for a perfectly shippable DMG. The meaningful
    # probe is that the .APP assesses as accepted (mounting the stapled DMG ingests the
    # ticket into the local database, so this also proves offline launch works). Mount,
    # assess the app with `-t exec`, unmount.
    echo "🔎 Verifying Gatekeeper acceptance of the app inside the DMG..."
    MOUNT_POINT="$(hdiutil attach "$DMG_PATH" -nobrowse -noautoopen | grep -o '/Volumes/.*' | head -1)"
    if [ -z "$MOUNT_POINT" ]; then
        echo "❌ Could not mount the DMG to verify it."
        exit 1
    fi
    SPCTL_OUT="$(spctl -a -t exec -vvv "$MOUNT_POINT/$APP_NAME.app" 2>&1 || true)"
    echo "$SPCTL_OUT"
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    if ! printf '%s' "$SPCTL_OUT" | grep -q 'source=Notarized Developer ID'; then
        echo "❌ Gatekeeper did not accept the app as 'Notarized Developer ID' — not shippable."
        exit 1
    fi
    echo "✅ Notarized + stapled; app inside is Gatekeeper-accepted (Notarized Developer ID)."
else
    echo ""
    echo "⚠️  ============================================"
    echo "⚠️  DMG is NOT NOTARIZED."
    echo "⚠️  Gatekeeper will block it ('cannot be checked' / 'damaged') on any Mac"
    echo "⚠️  other than this build host. For a distributable build, re-run with a"
    echo "⚠️  Developer ID cert and notarization enabled:"
    echo "⚠️    NOTARIZE=1 SIGN_IDENTITY='Developer ID Application: Name (TEAMID)' \\"
    echo "⚠️      NOTARY_PROFILE=<profile> bash scripts/build_dmg.sh"
    echo "⚠️  See docs/PUBLISHING.md §2 for the one-time cert + profile setup."
    echo "⚠️  ============================================"
fi

echo ""
echo "============================================"
echo "✅ Done! Files created:"
echo "   📱 App:  $APP_BUNDLE"
echo "   💿 DMG:  $DMG_PATH"
echo "============================================"
echo ""
echo "To install: Open the DMG and drag NoCornyTracer to Applications"
