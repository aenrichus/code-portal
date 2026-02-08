#!/bin/bash
set -euo pipefail

# Generate a DMG background image for the drag-to-install window.
# Usage: ./scripts/generate-dmg-background.sh [output.png]
#
# Creates a 600x400 dark gradient background with a subtle arrow
# pointing from the app icon position to the Applications folder.
# Output: scripts/dmg-background.png (or specified path)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/dmg-background.png}"

echo "Generating DMG background..."

swift - "$OUTPUT" <<'SWIFT'
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    fputs("Usage: generate-dmg-background.sh [output.png]\n", stderr)
    exit(1)
}

let width = 600
let height = 400
let outputPath = args[1]

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// --- Light gradient background ---
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let gradientColors = [
    CGColor(colorSpace: colorSpace, components: [0.90, 0.90, 0.92, 1.0])!,  // Top: light
    CGColor(colorSpace: colorSpace, components: [0.82, 0.82, 0.86, 1.0])!   // Bottom: slightly darker
]
let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors as CFArray, locations: [0.0, 1.0])!
ctx.drawLinearGradient(gradient,
    start: CGPoint(x: 0, y: CGFloat(height)),
    end: CGPoint(x: 0, y: 0),
    options: [])

// --- Subtle arrow in the center ---
let arrowCenterX: CGFloat = 300
let arrowCenterY: CGFloat = 215

// Draw a chevron-style arrow pointing right
ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.55, 0.55, 0.62, 0.7])!)
ctx.setLineWidth(2.5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let chevronSize: CGFloat = 18
ctx.move(to: CGPoint(x: arrowCenterX - chevronSize/2, y: arrowCenterY + chevronSize))
ctx.addLine(to: CGPoint(x: arrowCenterX + chevronSize/2, y: arrowCenterY))
ctx.addLine(to: CGPoint(x: arrowCenterX - chevronSize/2, y: arrowCenterY - chevronSize))
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to generate PNG\n", stderr)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outputPath))
SWIFT

echo "Done: $OUTPUT"
