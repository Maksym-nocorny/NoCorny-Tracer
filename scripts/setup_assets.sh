#!/bin/bash
set -e

ASSETS_DIR="Sources/NoCornyTracer/Assets.xcassets"
APP_ICON_DIR="$ASSETS_DIR/AppIcon.appiconset"
MENU_ICON_DIR="$ASSETS_DIR/MenuBarIcon.imageset"

mkdir -p "$APP_ICON_DIR"
mkdir -p "$MENU_ICON_DIR"

# Ensure we have the logos
LOGO="assets/NoCorny Tracer Ico.png"
if [ ! -f "$LOGO" ]; then
    echo "Logo not found!"
    exit 1
fi

TRAY_LOGO="assets/NoCorny Tracer Tray Ico.png"
if [ ! -f "$TRAY_LOGO" ]; then
    echo "Tray Logo not found!"
    # Continue without the tray logo instead of exiting
    # exit 1
fi

# Resize App Icons using sips
echo "Resizing App Icons..."
sips -z 16 16 "$LOGO" --out "$APP_ICON_DIR/mac16.png" > /dev/null
sips -z 32 32 "$LOGO" --out "$APP_ICON_DIR/mac32.png" > /dev/null
sips -z 64 64 "$LOGO" --out "$APP_ICON_DIR/mac64.png" > /dev/null
sips -z 128 128 "$LOGO" --out "$APP_ICON_DIR/mac128.png" > /dev/null
sips -z 256 256 "$LOGO" --out "$APP_ICON_DIR/mac256.png" > /dev/null
sips -z 512 512 "$LOGO" --out "$APP_ICON_DIR/mac512.png" > /dev/null
sips -z 1024 1024 "$LOGO" --out "$APP_ICON_DIR/mac1024.png" > /dev/null

# Create AppIcon Contents.json
cat << 'JSON' > "$APP_ICON_DIR/Contents.json"
{
  "images" : [
    { "filename" : "mac16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "mac32.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "mac32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "mac64.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "mac128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "mac256.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "mac256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "mac512.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "mac512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "mac1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# Menu bar icons
echo "Processing Menu Bar Icons..."
sips -z 16 16 "$TRAY_LOGO" --out "$MENU_ICON_DIR/icon_16.png" > /dev/null
sips -z 32 32 "$TRAY_LOGO" --out "$MENU_ICON_DIR/icon_32.png" > /dev/null
sips -z 48 48 "$TRAY_LOGO" --out "$MENU_ICON_DIR/icon_48.png" > /dev/null

# Important: "template-rendering-intent": "template" tells macOS to recolor it for dark/light mode
cat << 'JSON' > "$MENU_ICON_DIR/Contents.json"
{
  "images" : [
    { "filename" : "icon_16.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "icon_32.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "icon_48.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
JSON

echo "Done!"
