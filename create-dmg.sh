#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Heimdall"
APP_PATH="$SCRIPT_DIR/build/$APP_NAME.app"
DMG_NAME="Heimdall-1.0"
DMG_PATH="$SCRIPT_DIR/build/$DMG_NAME.dmg"
DMG_TEMP="$SCRIPT_DIR/build/dmg_staging"
VOL_NAME="Heimdall — Source Matching Audio Switcher"

echo "Creating DMG installer..."
echo ""

# Always do a clean app bundle build
echo "Building release..."
cd "$SCRIPT_DIR"
swift build -c release

# Create app bundle structure
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy binary
cp ".build/release/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"

# Copy resource bundle (contains banner image)
if [ -d ".build/release/Heimdall_Heimdall.bundle" ]; then
    cp -R ".build/release/Heimdall_Heimdall.bundle" "$APP_PATH/Contents/Resources/"
fi

# Copy banner image directly too (for easy access)
if [ -f "Sources/heimdall_banner.png" ]; then
    cp "Sources/heimdall_banner.png" "$APP_PATH/Contents/Resources/"
fi

# Generate AppIcon.icns from banner image
echo "Generating app icon..."
ICONSET="$SCRIPT_DIR/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# Crop center 1024x1024 from the 1024x1536 banner
sips -c 1024 1024 --padToHeightWidth 1024 1024 \
    "Sources/heimdall_banner.png" \
    --out "$ICONSET/source.png" > /dev/null 2>&1
# Generate all required icon sizes
for SIZE in 16 32 64 128 256 512; do
    sips -z $SIZE $SIZE "$ICONSET/source.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" > /dev/null 2>&1
    DOUBLE=$((SIZE * 2))
    sips -z $DOUBLE $DOUBLE "$ICONSET/source.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" > /dev/null 2>&1
done
# 512@2x is 1024
cp "$ICONSET/source.png" "$ICONSET/icon_512x512@2x.png"
rm "$ICONSET/source.png"
iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Write Info.plist
cat > "$APP_PATH/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Heimdall</string>
    <key>CFBundleDisplayName</key>
    <string>Heimdall — Source Matching Audio Switcher</string>
    <key>CFBundleIdentifier</key>
    <string>com.heimdall.audio</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>Heimdall</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Heimdall needs access to music players to detect what's currently playing and its audio format.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Heimdall monitors the system audio format to automatically match your DAC's sample rate to the source material.</string>
</dict>
</plist>
PLIST

# Ad-hoc code sign the app
echo "Code signing..."
codesign --force --deep --sign - "$APP_PATH"

echo "✓ App bundle ready"

# Clean staging
rm -rf "$DMG_TEMP"
rm -f "$DMG_PATH"
mkdir -p "$DMG_TEMP"

# Copy app to staging
cp -R "$APP_PATH" "$DMG_TEMP/"

# Create Applications symlink (for drag-to-install)
ln -s /Applications "$DMG_TEMP/Applications"

# Include uninstall script
cp "$SCRIPT_DIR/uninstall.sh" "$DMG_TEMP/Uninstall Heimdall.command"
chmod +x "$DMG_TEMP/Uninstall Heimdall.command"

# Create a README in the DMG
cat > "$DMG_TEMP/README.txt" << 'EOF'
Heimdall — Source Matching Audio Switcher
=========================================

Drag Heimdall.app to the Applications folder to install.

What it does:
macOS resamples all audio to a single fixed rate before sending
it to your hardware. Heimdall automatically matches your DAC's
sample rate to the original source, so your music arrives
untouched — no resampling, no manual Audio MIDI Setup changes.

After installing:
• Open Heimdall from Applications or Spotlight
• It auto-detects your USB DAC
• Leave it running — it handles everything

To uninstall:
• Quit Heimdall
• Delete it from Applications
• Remove from System Settings > General > Login Items

More info: github.com/Black-JL/Heimdall
EOF

# Create the DMG
echo "Packaging..."
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

# Clean up staging
rm -rf "$DMG_TEMP"

echo ""
echo "================================================"
echo "  DMG created: $DMG_PATH"
echo "  Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "  To distribute:"
echo "  • Share the .dmg file directly"
echo "  • Upload to GitHub Releases"
echo "  • Send to Schiit Audio"
echo "================================================"
