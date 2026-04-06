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

# Build if needed
if [ ! -f "$APP_PATH/Contents/MacOS/$APP_NAME" ]; then
    echo "Building release..."
    cd "$SCRIPT_DIR"
    swift build -c release
    mkdir -p "$APP_PATH/Contents/MacOS"
    mkdir -p "$APP_PATH/Contents/Resources"
    cp ".build/release/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"
fi

# Clean staging
rm -rf "$DMG_TEMP"
rm -f "$DMG_PATH"
mkdir -p "$DMG_TEMP"

# Copy app to staging
cp -R "$APP_PATH" "$DMG_TEMP/"

# Create Applications symlink (for drag-to-install)
ln -s /Applications "$DMG_TEMP/Applications"

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
