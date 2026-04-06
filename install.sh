#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Heimdall"
APP_SRC="$SCRIPT_DIR/build/$APP_NAME.app"
APP_DEST="/Applications/$APP_NAME.app"

echo "═══════════════════════════════════════════════"
echo "  Heimdall — Lossless Audio Switcher"
echo "  Installer"
echo "═══════════════════════════════════════════════"
echo

# Build if needed
if [ ! -f "$APP_SRC/Contents/MacOS/$APP_NAME" ]; then
    echo "Building..."
    cd "$SCRIPT_DIR"
    swift build -c release 2>&1

    mkdir -p "$APP_SRC/Contents/MacOS"
    mkdir -p "$APP_SRC/Contents/Resources"
    cp ".build/release/$APP_NAME" "$APP_SRC/Contents/MacOS/$APP_NAME"
    echo "✓ Built"
    echo
fi

# Remove old version
if [ -d "$APP_DEST" ]; then
    echo "Removing previous installation..."
    rm -rf "$APP_DEST"
fi

# Also remove legacy AudioMatcher if present
rm -rf /Applications/AudioMatcher.app
osascript -e 'tell application "System Events" to delete login item "AudioMatcher"' 2>/dev/null || true

# Copy to Applications
echo "Installing to /Applications..."
cp -R "$APP_SRC" "$APP_DEST"
echo "✓ Installed to $APP_DEST"
echo

# Add as Login Item
echo "Adding to Login Items (auto-start on login)..."
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"/Applications/$APP_NAME.app\", hidden:false}" 2>/dev/null || true
echo "✓ Added to Login Items"
echo

echo "═══════════════════════════════════════════════"
echo "  Installation complete!"
echo ""
echo "  Heimdall is now in /Applications"
echo "  • Search 'Heimdall' or 'Lossless' in Spotlight"
echo "  • Auto-starts on login"
echo "  • Auto-detects your DAC when plugged in"
echo ""
echo "  To launch now:"
echo "    open /Applications/Heimdall.app"
echo "═══════════════════════════════════════════════"
