#!/usr/bin/env bash
set -euo pipefail

# Renders assets/icon-source.svg into all PNG sizes the app needs.
# Source-of-truth for the icon design lives in the SVG; rerun this script
# any time you edit it.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SVG="$PROJECT_DIR/assets/icon-source.svg"
MASTER_PNG="$PROJECT_DIR/assets/NoCorny Tracer Ico.png"
APPICONSET="$PROJECT_DIR/Sources/NoCornyTracer/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SOURCE_SVG" ]; then
    echo "❌ Source SVG not found at $SOURCE_SVG"
    exit 1
fi

if ! command -v rsvg-convert > /dev/null 2>&1; then
    echo "📦 librsvg (rsvg-convert) not found. Installing via Homebrew..."
    if ! command -v brew > /dev/null 2>&1; then
        echo "❌ Homebrew is required. Install from https://brew.sh first."
        exit 1
    fi
    brew install librsvg
fi

render() {
    local size="$1"
    local out="$2"
    rsvg-convert -w "$size" -h "$size" "$SOURCE_SVG" -o "$out"
    echo "  ✓ ${size}×${size} → $(basename "$out")"
}

echo "🎨 Rendering master 1024×1024..."
render 1024 "$MASTER_PNG"

echo ""
echo "🖼  Rendering AppIcon.appiconset..."
mkdir -p "$APPICONSET"
render 16   "$APPICONSET/mac16.png"
render 32   "$APPICONSET/mac32.png"
render 64   "$APPICONSET/mac64.png"
render 128  "$APPICONSET/mac128.png"
render 256  "$APPICONSET/mac256.png"
render 512  "$APPICONSET/mac512.png"
render 1024 "$APPICONSET/mac1024.png"

echo ""
echo "✅ Done. Run 'bash scripts/build_dmg.sh' to package the new icon into the app."
