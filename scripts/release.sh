#!/bin/bash
set -e

# === NoCornyTracer Release Script ===
# Builds the app, creates a DMG, signs it for Sparkle, and updates appcast.xml.
#
# Usage:
#   bash scripts/release.sh            # build, sign, update appcast, print deploy steps
#   bash scripts/release.sh --publish  # additionally create the GitHub release and push appcast (asset-first)
#
# Prerequisites:
#   - Sparkle generate_keys has been run (private key in Keychain)
#   - sign_update tool available at .build/artifacts/sparkle/Sparkle/bin/sign_update

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
APPCAST="$PROJECT_DIR/appcast.xml"
GH="/opt/homebrew/bin/gh"   # gh is not on the default PATH (see MASTER.md)

# Optional --publish: perform the deploy steps in the correct (asset-first) order
# instead of only printing instructions.
PUBLISH=0
if [ "${1:-}" = "--publish" ]; then
    PUBLISH=1
fi

# Read version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/Sources/NoCornyTracer/Info.plist")
DMG_NAME="NoCornyTracer-$VERSION"
DMG_PATH="$PROJECT_DIR/dist/$DMG_NAME.dmg"
GITHUB_REPO="Maksym-nocorny/NoCorny-Tracer"

echo "🚀 Release NoCornyTracer v$VERSION"
echo ""

# === Step 1: Build DMG ===
echo "📦 Building DMG..."
# Signal a release build so build_dmg.sh refuses to ad-hoc sign a public distribution
# when the signing identity is missing (it would otherwise silently fall back).
RELEASE_BUILD=1 bash "$PROJECT_DIR/scripts/build_dmg.sh"

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

# Temporarily disable errexit around sign_update so a failure (e.g. missing private
# key) reaches the guidance block below instead of killing the script silently (Fix 5).
set +e
SIGNATURE=$("$SIGN_UPDATE" "$DMG_PATH" 2>&1)
SIGN_RC=$?
set -e
echo "✅ Signature: $SIGNATURE"

# Extract edSignature and length
ED_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
DMG_SIZE=$(stat -f%z "$DMG_PATH")

if [ -z "$ED_SIGNATURE" ] || [ "$SIGN_RC" -ne 0 ]; then
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

# Idempotency guard (B8.4): re-running release.sh for a version that already has an
# <item> in the feed would otherwise sed-insert a SECOND duplicate <item> for it.
# Keyed on the exact <sparkle:version> marker (unique per release). If present, skip
# the insert so re-runs are a no-op on the appcast; the build/sign/instruction steps
# above and below still run. To intentionally replace an item, delete its <item>
# block from appcast.xml by hand and re-run.
if grep -q "<sparkle:version>$VERSION</sparkle:version>" "$APPCAST"; then
    echo "⚠️  appcast.xml already has an <item> for v$VERSION — skipping insert (re-run safe)."
    echo "    To replace it, delete the existing <item> block for v$VERSION from appcast.xml and re-run."
else
    DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$DMG_NAME.dmg"
    # RFC-822 requires English month/day abbreviations. Force the C locale so the
    # pubDate is correct regardless of the maintainer's environment locale.
    PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')

    # Insert new item AFTER <language>en</language>
    ITEM="    <item>\\
      <title>Version $VERSION</title>\\
      <pubDate>$PUB_DATE</pubDate>\\
      <sparkle:version>$VERSION</sparkle:version>\\
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>\\
      <enclosure\\
        url=\\\"$DOWNLOAD_URL\\\"\\
        sparkle:edSignature=\\\"$ED_SIGNATURE\\\"\\
        length=\\\"$DMG_SIZE\\\"\\
        type=\\\"application/octet-stream\\\"/>\\
    </item>"

    # Use sed to insert after <language>en</language>
    sed -i '' "s|<language>en</language>|<language>en</language>\\
$ITEM|" "$APPCAST"

    echo "✅ appcast.xml updated"
fi

# === Step 4: Deploy (asset-first order) ===
if [ "$PUBLISH" = "1" ]; then
    echo ""
    echo "🚀 Publishing (asset-first)..."
    # Step 1: create the GitHub release WITH the DMG asset, so the URL in appcast.xml
    # resolves before any client fetches the feed.
    if ! "$GH" release create "v$VERSION" "$DMG_PATH" --title "v$VERSION" --notes "Release v$VERSION"; then
        echo "❌ 'gh release create' failed — NOT pushing appcast.xml (would 404 Sparkle clients)."
        exit 1
    fi
    echo "✅ GitHub release v$VERSION created with asset"
    # Step 2: only now publish the feed pointing at the live asset.
    git -C "$PROJECT_DIR" add appcast.xml
    git -C "$PROJECT_DIR" commit -m "Release v$VERSION"
    git -C "$PROJECT_DIR" push
    echo "✅ appcast.xml committed and pushed"
    echo "============================================"
    echo "✅ Release v$VERSION published!"
    echo "============================================"
else
    echo ""
    echo "============================================"
    echo "✅ Release v$VERSION ready!"
    echo ""
    echo "⚠️  Create the GitHub release (upload the DMG) BEFORE pushing appcast.xml,"
    echo "    or Sparkle clients will hit a 404 while the feed points at a missing asset."
    echo ""
    echo "Next steps (asset-first order):"
    echo "  1. Create the GitHub Release (uploads the asset):"
    echo "     $GH release create v$VERSION '$DMG_PATH' --title 'v$VERSION' --notes 'Release v$VERSION'"
    echo ""
    echo "  2. Commit and push appcast.xml (now the feed points at a live asset):"
    echo "     git add appcast.xml && git commit -m 'Release v$VERSION' && git push"
    echo ""
    echo "  Or create the release manually at: https://github.com/$GITHUB_REPO/releases/new"
    echo "     - Tag: v$VERSION"
    echo "     - Upload: $DMG_PATH"
    echo ""
    echo "  Tip: run 'bash scripts/release.sh --publish' to perform both steps in the correct order."
    echo "============================================"
fi
