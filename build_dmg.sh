#!/bin/bash
set -e

# === Configuration ===
APP_NAME="BetterLoom"
BUNDLE_ID="com.betterloom.app"
VERSION="1.3.1"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
DMG_DIR="$PROJECT_DIR/dist"
DMG_NAME="$APP_NAME-$VERSION"
DMG_PATH="$DMG_DIR/$DMG_NAME.dmg"

echo "🔨 Building $APP_NAME v$VERSION..."

# === Step 1: Build release binary ===
cd "$PROJECT_DIR"
swift build -c release 2>&1

echo "✅ Build complete"

# === Step 2: Create .app bundle structure ===
echo "📦 Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy the binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy the SPM resource bundle to Contents/Resources and symlink from Contents/MacOS/
# SPM's auto-generated Bundle.module accessor looks in Bundle.main.bundleURL which
# resolves to Contents/MacOS/ for an executable. The symlink bridges the two locations.
if [ -d "$BUILD_DIR/BetterLoom_BetterLoom.bundle" ]; then
    cp -R "$BUILD_DIR/BetterLoom_BetterLoom.bundle" "$APP_BUNDLE/Contents/Resources/"
    ln -s "../Resources/BetterLoom_BetterLoom.bundle" "$APP_BUNDLE/Contents/MacOS/BetterLoom_BetterLoom.bundle"
fi

# Copy Info.plist
cp "$PROJECT_DIR/Sources/BetterLoom/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

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
if [ -f "$PROJECT_DIR/app logo.png" ]; then
    echo "🎨 Creating app icon..."
    ICONSET_DIR="$PROJECT_DIR/dist/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    sips -z 16 16     "$PROJECT_DIR/app logo.png" --out "$ICONSET_DIR/icon_16x16.png"      > /dev/null
    sips -z 32 32     "$PROJECT_DIR/app logo.png" --out "$ICONSET_DIR/icon_16x16@2x.png"   > /dev/null
    sips -z 32 32     "$PROJECT_DIR/app logo.png" --out "$ICONSET_DIR/icon_32x32.png"      > /dev/null
    sips -z 64 64     "$PROJECT_DIR/app logo.png" --out "$ICONSET_DIR/icon_32x32@2x.png"   > /dev/null
    sips -z 128 128   "$PROJECT_DIR/app logo.png" --out "$ICONSET_DIR/icon_128x128.png"    > /dev/null
    sips -z 256 256   "$PROJECT_DIR/app logo.png" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "$PROJECT_DIR/app logo.png" --out "$ICONSET_DIR/icon_256x256.png"    > /dev/null
    sips -z 512 512   "$PROJECT_DIR/app logo.png" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "$PROJECT_DIR/app logo.png" --out "$ICONSET_DIR/icon_512x512.png"    > /dev/null
    sips -z 1024 1024 "$PROJECT_DIR/app logo.png" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
    echo "✅ App icon created"
fi

# === Step 3: Code sign with self-signed certificate and entitlements ===
echo "🔏 Code signing..."
ENTITLEMENTS="$PROJECT_DIR/Sources/BetterLoom/BetterLoom.entitlements"
SIGN_IDENTITY="BetterLoom Dev"

# Check if the signing identity exists
if security find-identity -p codesigning | grep -q "$SIGN_IDENTITY"; then
    if [ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
        codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
        codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
        codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi
    if [ -d "$APP_BUNDLE/Contents/Frameworks/SparkleCore.framework" ]; then
        codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/SparkleCore.framework"
    fi
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
    echo "✅ Code signed with '$SIGN_IDENTITY' certificate"
else
    echo "⚠️  '$SIGN_IDENTITY' certificate not found, falling back to ad-hoc signing"
    if [ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
        codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
        codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
        codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi
    if [ -d "$APP_BUNDLE/Contents/Frameworks/SparkleCore.framework" ]; then
        codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/SparkleCore.framework"
    fi
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
    echo "✅ Code signed (ad-hoc) with entitlements"
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

# Create Applications symlink
ln -s /Applications "$STAGING/Applications"

# Create the DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

# Clean up staging
rm -rf "$STAGING"

echo ""
echo "============================================"
echo "✅ Done! Files created:"
echo "   📱 App:  $APP_BUNDLE"
echo "   💿 DMG:  $DMG_PATH"
echo "============================================"
echo ""
echo "To install: Open the DMG and drag BetterLoom to Applications"
