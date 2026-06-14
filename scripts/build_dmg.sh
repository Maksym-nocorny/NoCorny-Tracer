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
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
DMG_DIR="$PROJECT_DIR/dist"
DMG_NAME="NoCornyTracer-$VERSION"
DMG_PATH="$DMG_DIR/$DMG_NAME.dmg"

echo "🔨 Building $APP_NAME v$VERSION..."

# === Step 1: Build release binary ===
cd "$PROJECT_DIR"
# Build a universal (arm64 + x86_64) binary so Intel Macs can run the app.
# SwiftPM emits a fat binary directly at .build/release/$BINARY_NAME.
# Note: Info.plist is a link-time input (-sectcreate in Package.swift) that SwiftPM
# does NOT track, so a clean release link is needed to pick up plist edits. We remove
# only the cached executable (NOT all of .build — that would wipe the Sparkle
# artifacts and create-dmg cache) to force the sectcreate to re-run.
rm -f "$PROJECT_DIR/.build/release/$BINARY_NAME"
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
    # Add rpath so the executable can find the frameworks
    install_name_tool -add_rpath @executable_path/../Frameworks "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
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
# The signing identity is explicit and overridable: point SIGN_IDENTITY at a real
# Developer ID to ship a distributable build. The historical default is kept.
SIGN_IDENTITY="${SIGN_IDENTITY:-NoCornyTracer Dev}"
# A stable designated requirement keyed on the bundle id keeps Sparkle in-place
# updates and TCC grants intact across machines and across both signing paths.
DESIGNATED_REQ="=designated => identifier \"$BUNDLE_ID\""

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

# Sign Sparkle's nested code (Autoupdate, Updater.app) and the frameworks.
# Failures are surfaced (no 2>/dev/null || true) so a path drift or a genuine
# signing error hard-fails the build under `set -e` instead of shipping a
# subtly-broken DMG (Fix 10). $1 is the codesign identity ("-" for ad-hoc).
sign_frameworks() {
    local identity="$1"
    if [ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
        local version_dir
        if ! version_dir=$(resolve_sparkle_version_dir); then
            echo "❌ Could not resolve Sparkle.framework versioned directory (Versions/Current or Versions/[A-Z])"
            exit 1
        fi
        if [ -e "$version_dir/Autoupdate" ]; then
            codesign --force --sign "$identity" "$version_dir/Autoupdate"
        else
            echo "❌ Sparkle Autoupdate not found at $version_dir/Autoupdate"
            exit 1
        fi
        if [ -e "$version_dir/Updater.app" ]; then
            codesign --force --sign "$identity" "$version_dir/Updater.app"
        else
            echo "❌ Sparkle Updater.app not found at $version_dir/Updater.app"
            exit 1
        fi
        codesign --force --sign "$identity" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi
    if [ -d "$APP_BUNDLE/Contents/Frameworks/SparkleCore.framework" ]; then
        codesign --force --sign "$identity" "$APP_BUNDLE/Contents/Frameworks/SparkleCore.framework"
    fi
}

# Check if the signing identity exists
if security find-identity -p codesigning | grep -q "$SIGN_IDENTITY"; then
    sign_frameworks "$SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" --requirements "$DESIGNATED_REQ" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
    echo "✅ Code signed with '$SIGN_IDENTITY' certificate"
elif [ "${RELEASE_BUILD:-0}" = "1" ]; then
    # Release builds must not silently ad-hoc sign a public distribution.
    echo "❌ Signing identity '$SIGN_IDENTITY' not found, and RELEASE_BUILD=1."
    echo "   Refusing to ad-hoc sign a release. Either:"
    echo "     - import the '$SIGN_IDENTITY' identity, or"
    echo "     - export SIGN_IDENTITY='Developer ID Application: …' pointing at a real cert."
    exit 1
else
    # Local/test build: ad-hoc fallback is allowed but loudly marked as non-distributable.
    echo "⚠️  Signing identity '$SIGN_IDENTITY' not found — falling back to ad-hoc signing"
    echo "⚠️  SIGNED MODE: ad-hoc — NOT for distribution"
    sign_frameworks -
    codesign --force --sign - --requirements "$DESIGNATED_REQ" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
    echo "✅ Code signed (ad-hoc) with a stable designated requirement"
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

echo ""
echo "============================================"
echo "✅ Done! Files created:"
echo "   📱 App:  $APP_BUNDLE"
echo "   💿 DMG:  $DMG_PATH"
echo "============================================"
echo ""
echo "To install: Open the DMG and drag NoCornyTracer to Applications"
