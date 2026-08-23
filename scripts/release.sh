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

# Load the maintainer's signing config so `bash scripts/release.sh` just works without
# re-typing env vars. This file is gitignored and must contain ONLY non-secrets — the
# notarytool keychain-profile NAME and (optionally) the SIGN_IDENTITY. The actual
# app-specific password lives in the Keychain (see scripts/setup_signing.sh), never here.
# `set -a` is load-bearing: build_dmg.sh runs as a CHILD process, so a plain `.` would
# leave NOTARY_PROFILE as a shell-local variable it never sees, and notarization would
# fail with "no notary credentials provided" on an otherwise perfect build.
if [ -f "$PROJECT_DIR/scripts/release.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/scripts/release.env"
    set +a
fi

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

# The version must actually differ from the last release. Nothing else checks this: the
# build guard proves the EMBEDDED plist matches the source one, never that the source moved.
# On 2026-08-23 that gap shipped a build whose bug-report scoping keys on the version
# string, left at the previous release's value - so the mechanism matched the old build's
# own log headers and excluded nothing it was built to exclude.
#
# The first cut of this guard grepped `sparkle:version="..."` - an attribute form this feed
# has never used. It matched nothing, so it passed everything: a guard that silently reads
# nothing is the same failure it was written to catch. Hence two rules now. Compare against
# EVERY published version, not just the newest, so re-cutting an older one is caught too;
# and refuse to run at all when the feed yields no versions, rather than reporting all clear
# on an empty read.
RELEASED_VERSIONS=$(grep -oE '<sparkle:version>[^<]+</sparkle:version>' "$PROJECT_DIR/appcast.xml" 2>/dev/null | sed -E 's#</?sparkle:version>##g' || true)
if [ -z "$RELEASED_VERSIONS" ]; then
    echo "❌ No <sparkle:version> entries found in $PROJECT_DIR/appcast.xml."
    echo "   Either the feed is empty or its format changed. Refusing to release blind:"
    echo "   this check cannot tell 'nothing published yet' from 'I can no longer read it'."
    exit 1
fi
if printf '%s\n' "$RELEASED_VERSIONS" | grep -qxF "$VERSION"; then
    echo "❌ Info.plist is still $VERSION, which is already published in appcast.xml."
    echo "   Bump BOTH CFBundleShortVersionString and CFBundleVersion before releasing."
    exit 1
fi
# Nothing else runs the test suite. There is no CI on this repo, and a release is the one
# moment where "the tests were green when I last looked" stops being good enough - the DMG
# built here goes out to every installed copy through Sparkle within the hour. Three seconds.
#
# NCT_SKIP_TESTS=1 exists for re-cutting a release whose build failed downstream (notarization,
# a GitHub outage) without re-running a suite that just passed. It is not for a red suite.
if [ "${NCT_SKIP_TESTS:-0}" != "1" ]; then
    echo "🧪 Running tests before building a release..."
    if ! swift test --package-path "$PROJECT_DIR" > /tmp/nct-release-tests.log 2>&1; then
        echo "❌ Tests failed — refusing to cut a release. Last 30 lines:"
        tail -30 /tmp/nct-release-tests.log
        exit 1
    fi
    grep -E "Executed [0-9]+ tests" /tmp/nct-release-tests.log | tail -1
    echo "✅ Tests pass"
fi

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
# <item> in the feed must not sed-insert a SECOND duplicate <item> for it. Keyed on the
# exact <sparkle:version> marker (unique per release).
#
# Skipping the item outright is NOT safe, though, and that cost us a broken v3.16.1 feed
# on 2026-08-04. A re-run REBUILDS the DMG, and DMGs are not byte-reproducible — the
# rebuild differed from the first by 8 bytes. The kept <item> therefore described the
# FIRST build while `--publish` uploaded the SECOND, and Sparkle verifies edSignature
# against the bytes it downloads, so every client's update would have failed signature
# validation. Refresh the enclosure in place instead: idempotent when nothing changed,
# self-healing when the payload did.
if grep -q "<sparkle:version>$VERSION</sparkle:version>" "$APPCAST"; then
    VERSION_MARKER="<sparkle:version>$VERSION</sparkle:version>"
    EXISTING=$(awk -v v="$VERSION_MARKER" '
        index($0, v) { inItem = 1 }
        inItem && /sparkle:edSignature="/ {
            match($0, /edSignature="[^"]*"/); s = substr($0, RSTART + 13, RLENGTH - 14)
        }
        inItem && /length="/ {
            match($0, /length="[^"]*"/); l = substr($0, RSTART + 8, RLENGTH - 9)
        }
        inItem && /<\/item>/ { print s "|" l; exit }
    ' "$APPCAST")

    if [ "$EXISTING" = "$ED_SIGNATURE|$DMG_SIZE" ]; then
        echo "✅ appcast.xml already has a matching <item> for v$VERSION — nothing to update."
    else
        awk -v v="$VERSION_MARKER" -v sig="$ED_SIGNATURE" -v len="$DMG_SIZE" '
            index($0, v) { inItem = 1 }
            inItem && /sparkle:edSignature="/ { sub(/edSignature="[^"]*"/, "edSignature=\"" sig "\"") }
            inItem && /length="/ { sub(/length="[^"]*"/, "length=\"" len "\"") }
            inItem && /<\/item>/ { inItem = 0 }
            { print }
        ' "$APPCAST" > "$APPCAST.tmp" && mv "$APPCAST.tmp" "$APPCAST"

        echo "⚠️  appcast.xml had an <item> for v$VERSION describing a different build."
        echo "    Refreshed it to match the DMG this run produced ($DMG_SIZE bytes)."
        if [ "$PUBLISH" = "1" ]; then
            echo "    The release asset is re-uploaded below, so feed and asset stay in step."
        else
            echo "    Re-upload the DMG to the v$VERSION release, or the feed will not match the asset."
        fi
    fi
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
    # Step 1: put the DMG on the release first, so the URL in appcast.xml resolves before
    # any client fetches the feed.
    #
    # On a re-run the release already exists and `gh release create` refuses outright. The
    # asset must still be replaced: the appcast above was just refreshed with THIS build's
    # signature, and leaving the previous build attached is exactly the feed/asset mismatch
    # that broke v3.16.1. --clobber overwrites the asset in place.
    if "$GH" release view "v$VERSION" >/dev/null 2>&1; then
        echo "ℹ️  Release v$VERSION already exists — replacing its asset with this build."
        if ! "$GH" release upload "v$VERSION" "$DMG_PATH" --clobber; then
            echo "❌ 'gh release upload' failed — NOT pushing appcast.xml (feed would not match the asset)."
            exit 1
        fi
        echo "✅ GitHub release v$VERSION asset replaced"
    else
        if ! "$GH" release create "v$VERSION" "$DMG_PATH" --title "v$VERSION" --notes "Release v$VERSION"; then
            echo "❌ 'gh release create' failed — NOT pushing appcast.xml (would 404 Sparkle clients)."
            exit 1
        fi
        echo "✅ GitHub release v$VERSION created with asset"
    fi
    # Step 2: only now publish the feed pointing at the live asset. Commit the version
    # bump + changelog alongside the feed (MASTER.md requires them per release) so the
    # pushed appcast and the tagged source agree.
    git -C "$PROJECT_DIR" add appcast.xml CHANGELOG.md Sources/NoCornyTracer/Info.plist
    # `git commit` exits non-zero with nothing staged, which under `set -e` would kill the
    # script AFTER the asset upload — reporting failure on a re-run that changed nothing.
    if git -C "$PROJECT_DIR" diff --cached --quiet; then
        echo "ℹ️  Nothing new to commit — feed and asset already agree."
    else
        git -C "$PROJECT_DIR" commit -m "Release v$VERSION"
    fi
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
