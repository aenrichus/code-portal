#!/bin/bash
set -euo pipefail

# Generate AppIcon.icns from source PNG using sips + iconutil.
# Usage: ./scripts/generate-icon.sh [source.png]
#
# If the source PNG has transparency, it is flattened onto a dark background
# (#1a1a2e) to prevent macOS from rendering transparent areas as white.
#
# Default source: ideas/cp_icon_transparent_2.png
# Output: Sources/Resources/AppIcon.icns

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE_PNG="${1:-$PROJECT_DIR/ideas/cp_icon_transparent_2.png}"
OUTPUT_ICNS="$PROJECT_DIR/Sources/Resources/AppIcon.icns"

if [ ! -f "$SOURCE_PNG" ]; then
    echo "ERROR: Source PNG not found: $SOURCE_PNG"
    exit 1
fi

TMPDIR_BASE=$(mktemp -d)
ICONSET_DIR="$TMPDIR_BASE/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

# Flatten transparency onto a dark background using CoreGraphics via Swift.
# This prevents macOS from showing white borders around transparent icon edges.
FLATTENED="$TMPDIR_BASE/flattened.png"

echo "Flattening transparency onto dark background..."
swift - "$SOURCE_PNG" "$FLATTENED" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard args.count == 3,
      let img = NSImage(contentsOfFile: args[1]) else {
    fputs("Failed to load image\n", stderr)
    exit(1)
}
let size = img.size
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// Fill with dark background matching the icon's dark color
NSColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0).setFill()
NSRect(origin: .zero, size: size).fill()
img.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: args[2]))
SWIFT

echo "Generating icon sizes from $(basename "$SOURCE_PNG")..."

# Required sizes for macOS .iconset (10 files)
declare -a SIZES=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)

for entry in "${SIZES[@]}"; do
    name="${entry%%:*}"
    size="${entry##*:}"
    sips -z "$size" "$size" "$FLATTENED" --out "$ICONSET_DIR/$name" >/dev/null 2>&1
    echo "  ${name} (${size}x${size})"
done

# Convert .iconset to .icns
echo "Creating AppIcon.icns..."
iconutil -c icns -o "$OUTPUT_ICNS" "$ICONSET_DIR"

# Clean up
rm -rf "$TMPDIR_BASE"

ICNS_SIZE=$(du -h "$OUTPUT_ICNS" | cut -f1)
echo "Done: $OUTPUT_ICNS ($ICNS_SIZE)"
