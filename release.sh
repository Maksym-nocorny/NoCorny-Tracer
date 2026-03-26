#!/bin/bash
set -e

# === BetterLoom Release Script ===
# Builds the app, creates a DMG, signs it for Sparkle, and updates appcast.xml.
#
# Usage: ./release.sh
#
# Prerequisites:
#   - Sparkle generate_keys has been run (private key in Keychain)
#   - sign_update tool available at .build/artifacts/sparkle/Sparkle/bin/sign_update

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
APPCAST="$PROJECT_DIR/appcast.xml"

# Read version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/Sources/BetterLoom/Info.plist")
DMG_NAME="BetterLoom-$VERSION"
DMG_PATH="$PROJECT_DIR/dist/$DMG_NAME.dmg"
GITHUB_REPO="Maksym-nocorny/NoCorny-Tracer"

echo "🚀 Release BetterLoom v$VERSION"
echo ""

# === Step 1: Build DMG ===
echo "📦 Building DMG..."
bash "$PROJECT_DIR/build_dmg.sh"

if [ ! -f "$DMG_PATH" ]; then
    echo "❌ DMG not found at $DMG_PATH"
    exit 1
fi
echo "✅ DMG built: $DMG_PATH"

# === Step 2: Sign DMG for Sparkle ===
echo ""
echo "🔏 Signing DMG for Sparkle..."

if [ ! -f "$SIGN_UPDATE" ]; then
    echo "❌ sign_update not found at $SIGN_UPDATE"
    echo "   Run: swift build to download Sparkle artifacts first"
    exit 1
fi

SIGNATURE=$("$SIGN_UPDATE" "$DMG_PATH" 2>&1)
echo "✅ Signature: $SIGNATURE"

# Extract edSignature and length
ED_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
DMG_SIZE=$(stat -f%z "$DMG_PATH")

if [ -z "$ED_SIGNATURE" ]; then
    echo "⚠️  Could not parse edSignature from sign_update output."
    echo "   Raw output: $SIGNATURE"
    echo ""
    echo "   You may need to run 'generate_keys' first:"
    echo "   $PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
    echo ""
    echo "   Then add the public key to Info.plist as SUPublicEDKey"
    exit 1
fi

# === Step 3: Update appcast.xml ===
echo ""
echo "📝 Updating appcast.xml..."

DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$DMG_NAME.dmg"
PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S %z')

# Insert new item before the closing </channel> tag
ITEM="    <item>\\
      <title>Version $VERSION</title>\\
      <pubDate>$PUB_DATE</pubDate>\\
      <sparkle:version>$VERSION</sparkle:version>\\
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>\\
      <enclosure\\
        url=\"$DOWNLOAD_URL\"\\
        sparkle:edSignature=\"$ED_SIGNATURE\"\\
        length=\"$DMG_SIZE\"\\
        type=\"application/octet-stream\"/>\\
    </item>"

# Use sed to insert before </channel>
sed -i '' "s|</channel>|$ITEM\\
  </channel>|" "$APPCAST"

echo "✅ appcast.xml updated"

# === Step 4: Instructions ===
echo ""
echo "============================================"
echo "✅ Release v$VERSION ready!"
echo ""
echo "Next steps:"
echo "  1. Commit and push appcast.xml:"
echo "     git add appcast.xml && git commit -m 'Release v$VERSION' && git push"
echo ""
echo "  2. Create a GitHub Release:"
echo "     gh release create v$VERSION '$DMG_PATH' --title 'v$VERSION' --notes 'Release v$VERSION'"
echo ""
echo "  Or manually at: https://github.com/$GITHUB_REPO/releases/new"
echo "     - Tag: v$VERSION"
echo "     - Upload: $DMG_PATH"
echo "============================================"
