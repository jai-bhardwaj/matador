#!/usr/bin/env bash
# Generate Matador's AppIcon.icns from scratch.
# Renders a 1024x1024 master via CoreGraphics, downscales to every required
# size, and packs into release/AppIcon.icns.
#
# Designed to be re-runnable: rm release/AppIcon.icns and re-run to regenerate.
# Requires Xcode (iconutil + sips ship with macOS, but the inline `swift`
# render needs the AppKit-capable Swift toolchain).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/AppIcon.icns"
ICONSET="$SCRIPT_DIR/AppIcon.iconset"
MASTER="$SCRIPT_DIR/_master_1024.png"

command -v swift >/dev/null 2>&1 || { echo "swift not found"; exit 1; }
command -v iconutil >/dev/null 2>&1 || { echo "iconutil not found"; exit 1; }
command -v sips >/dev/null 2>&1 || { echo "sips not found"; exit 1; }

echo "==> Rendering 1024x1024 master with CoreGraphics"

# The inline Swift program below draws the icon to a PNG.
# Design: dark rounded-square background, deep red cape silhouette, bold "M"
# overlay. Inspired by a matador's red cape (muleta).
swift - "$MASTER" <<'SWIFT'
import AppKit
import CoreGraphics

guard CommandLine.arguments.count >= 2 else { exit(1) }
let outPath = CommandLine.arguments[1]
let size: CGFloat = 1024

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(2) }

// Background: dark rounded square
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = size * 0.225  // macOS Big Sur+ icon corner ratio
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// Background gradient: deep slate at top → near-black at bottom
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let bgGrad = CGGradient(colorsSpace: cs, colors: [
    NSColor(red: 0.12, green: 0.10, blue: 0.13, alpha: 1).cgColor,
    NSColor(red: 0.05, green: 0.04, blue: 0.06, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGrad,
    start: CGPoint(x: size / 2, y: size),
    end: CGPoint(x: size / 2, y: 0),
    options: [])
ctx.restoreGState()

// Cape: sweeping crimson curve filling the right ~70% of the icon
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

let cape = CGMutablePath()
let cx = size * 0.18
let cy = size * 0.20
cape.move(to: CGPoint(x: cx, y: cy))
cape.addCurve(to: CGPoint(x: size * 0.95, y: size * 0.30),
              control1: CGPoint(x: size * 0.55, y: size * 0.05),
              control2: CGPoint(x: size * 0.85, y: size * 0.12))
cape.addCurve(to: CGPoint(x: size * 0.78, y: size * 0.90),
              control1: CGPoint(x: size * 1.05, y: size * 0.55),
              control2: CGPoint(x: size * 0.95, y: size * 0.78))
cape.addCurve(to: CGPoint(x: cx, y: cy),
              control1: CGPoint(x: size * 0.55, y: size * 1.02),
              control2: CGPoint(x: size * 0.22, y: size * 0.55))
cape.closeSubpath()

let capeGrad = CGGradient(colorsSpace: cs, colors: [
    NSColor(red: 0.92, green: 0.18, blue: 0.20, alpha: 1).cgColor,
    NSColor(red: 0.65, green: 0.08, blue: 0.12, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!

ctx.addPath(cape)
ctx.clip()
ctx.drawLinearGradient(capeGrad,
    start: CGPoint(x: size * 0.30, y: size * 0.85),
    end: CGPoint(x: size * 0.85, y: size * 0.15),
    options: [])
ctx.restoreGState()

// Soft cape shadow underneath for depth
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.02), blur: size * 0.04,
              color: NSColor(red: 0, green: 0, blue: 0, alpha: 0.5).cgColor)
ctx.addPath(cape)
ctx.setFillColor(NSColor(red: 0, green: 0, blue: 0, alpha: 0.001).cgColor) // shadow caster
ctx.fillPath()
ctx.restoreGState()

// Bold "M" letterform, off-white, sitting over the cape
let font = NSFont.systemFont(ofSize: size * 0.60, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(red: 0.98, green: 0.95, blue: 0.92, alpha: 1),
    .kern: -size * 0.02,
]
let str = NSAttributedString(string: "M", attributes: attrs)
let line = CTLineCreateWithAttributedString(str)
let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])

let textX = (size - bounds.width) / 2 - bounds.origin.x - size * 0.04
let textY = (size - bounds.height) / 2 - bounds.origin.y - size * 0.02

// Soft shadow under text for legibility against cape
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.015), blur: size * 0.025,
              color: NSColor(red: 0, green: 0, blue: 0, alpha: 0.6).cgColor)
ctx.textPosition = CGPoint(x: textX, y: textY)
CTLineDraw(line, ctx)
ctx.restoreGState()

guard let cgImage = ctx.makeImage() else { exit(3) }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else { exit(4) }
try pngData.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
SWIFT

[[ -f "$MASTER" ]] || { echo "master PNG not written"; exit 1; }

echo "==> Building iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Required sizes per Apple's icon spec
declare -a SIZES=(16 32 64 128 256 512 1024)
for sz in "${SIZES[@]}"; do
    sips -z "$sz" "$sz" "$MASTER" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
done
# @2x variants
for sz in 16 32 128 256 512; do
    double=$((sz * 2))
    sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
# iconutil expects these specific names — 1024 maps to icon_512x512@2x
mv "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png" 2>/dev/null || true

echo "==> Packing into AppIcon.icns"
iconutil --convert icns "$ICONSET" --output "$OUT"

rm -rf "$ICONSET" "$MASTER"

echo "✓ $OUT"
sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null || true
