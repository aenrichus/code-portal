#!/bin/bash
set -euo pipefail

# Build Code Portal.app and .dmg installer.
# Usage: ./scripts/build-app.sh
#
# Output: build/<build-number>/Code Portal.app
#         build/<build-number>/Code Portal.dmg  (drag-to-install DMG)
# Version: reads CFBundleVersion from Info.plist, increments it, writes back.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INFO_PLIST="$PROJECT_DIR/Sources/Resources/Info.plist"
BUILD_DIR="$PROJECT_DIR/build"

cd "$PROJECT_DIR"

# --- Increment build number ---
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
VERSIONED_DIR="$BUILD_DIR/$NEW_BUILD"
APP_DIR="$VERSIONED_DIR/Code Portal.app"

echo "=== Building Code Portal v${VERSION} (build ${NEW_BUILD}) ==="

# --- Build release binary ---
echo "Compiling..."
swift build -c release 2>&1 | grep -E "^(Build|error:|warning:)" || true

if [ ! -f ".build/release/CodePortal" ]; then
    echo "ERROR: Build failed"
    exit 1
fi

# --- Create .app bundle ---
rm -rf "$VERSIONED_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# Copy binary
cp .build/release/CodePortal "$APP_DIR/Contents/MacOS/CodePortal"

# Copy and augment Info.plist
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string CodePortal" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true

# Copy app icon
ICON_FILE="$PROJECT_DIR/Sources/Resources/AppIcon.icns"
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
    echo "WARNING: AppIcon.icns not found. Run scripts/generate-icon.sh to create it."
fi

# Copy third-party license notices (required by MIT license)
cp "$PROJECT_DIR/THIRD_PARTY_LICENSES" "$APP_DIR/Contents/Resources/THIRD_PARTY_LICENSES"

# --- Create DMG installer ---
echo "Creating DMG installer..."

DMG_NAME="Code Portal"
DMG_FINAL="$VERSIONED_DIR/${DMG_NAME}.dmg"
DMG_TEMP="$VERSIONED_DIR/${DMG_NAME}_rw.dmg"
STAGING_DIR=$(mktemp -d)

# Generate background image to a temp location
BG_TMPDIR=$(mktemp -d)
BG_TMPFILE="$BG_TMPDIR/background.png"
"$SCRIPT_DIR/generate-dmg-background.sh" "$BG_TMPFILE"

# Stage contents (app and Applications symlink)
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Create read-write DMG with 10MB extra space for background/icon/DS_Store
# HFS+ required for custom volume icon (SetFile -a C doesn't work on APFS)
STAGING_SIZE=$(du -sm "$STAGING_DIR" | cut -f1)
DMG_SIZE=$((STAGING_SIZE + 10))
hdiutil create -volname "$DMG_NAME" -srcfolder "$STAGING_DIR" \
    -ov -format UDRW -fs HFS+ -megabytes "$DMG_SIZE" "$DMG_TEMP" >/dev/null 2>&1

# Mount and style
MOUNT_DIR="/Volumes/$DMG_NAME"
hdiutil attach -readwrite -noverify -noautoopen "$DMG_TEMP" >/dev/null 2>&1

# Wait for volume to be fully mounted
sleep 1

# Add background image
mkdir -p "$MOUNT_DIR/.background"
cp "$BG_TMPFILE" "$MOUNT_DIR/.background/background.png"
rm -rf "$BG_TMPDIR"

# Configure Finder window appearance via AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DMG_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 700, 500}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "Code Portal.app" of container window to {155, 185}
        set position of item "Applications" of container window to {445, 185}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Set volume icon AFTER AppleScript (update without registering applications deletes it)
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -a C "$MOUNT_DIR"
fi

# Ensure Finder releases the volume
sync

# Unmount
hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 \
    -o "$DMG_FINAL" >/dev/null 2>&1
rm -f "$DMG_TEMP"

# Clean up staging
rm -rf "$STAGING_DIR"

DMG_SIZE=$(du -h "$DMG_FINAL" | cut -f1)

# --- Done ---
BINARY_SIZE=$(du -h "$APP_DIR/Contents/MacOS/CodePortal" | cut -f1)
echo ""
echo "=== Code Portal v${VERSION} (build ${NEW_BUILD}) ==="
echo "    Binary: ${BINARY_SIZE}"
echo "    App:    $APP_DIR"
echo "    DMG:    $DMG_FINAL (${DMG_SIZE})"
echo ""

# Reveal DMG in Finder
open -R "$DMG_FINAL"
