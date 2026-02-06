#!/bin/bash
set -euo pipefail

# Build Code Portal.app — produces a proper macOS .app bundle.
# Usage: ./scripts/build-app.sh
#
# Output: build/<build-number>/Code Portal.app (revealed in Finder)
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

# --- Done ---
BINARY_SIZE=$(du -h "$APP_DIR/Contents/MacOS/CodePortal" | cut -f1)
echo ""
echo "=== Code Portal v${VERSION} (build ${NEW_BUILD}) ==="
echo "    Binary: ${BINARY_SIZE}"
echo "    Path:   $APP_DIR"
echo ""

# Reveal in Finder
open -R "$APP_DIR"
