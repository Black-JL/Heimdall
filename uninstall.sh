#!/bin/bash
echo "Uninstalling Heimdall..."

killall Heimdall 2>/dev/null || true
echo "✓ Stopped running instance"

osascript -e 'tell application "System Events" to delete login item "Heimdall"' 2>/dev/null || true
echo "✓ Removed from Login Items"

rm -rf /Applications/Heimdall.app
echo "✓ Removed from /Applications"

# Also clean up legacy AudioMatcher if present
killall AudioMatcher 2>/dev/null || true
rm -rf /Applications/AudioMatcher.app
osascript -e 'tell application "System Events" to delete login item "AudioMatcher"' 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.audiomatcher" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.audiomatcher.plist"

echo ""
echo "Heimdall has been uninstalled."
