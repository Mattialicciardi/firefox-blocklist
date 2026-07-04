#!/bin/bash
# Genera l'icona dell'app in modo riproducibile: sorgente vettoriale disegnato
# via CoreGraphics, raster PNG per iconset Apple, poi .icns finale.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="FirefoxBlocklist"
ICONSET="${APP_NAME}.iconset"
RESOURCES_DIR="Resources"
WORK_DIR=".build/icon-work"
SOURCE_PNG="${WORK_DIR}/AppIcon-1024.png"
DRAW_SWIFT="${WORK_DIR}/draw-icon.swift"
DEST_ICNS="${RESOURCES_DIR}/AppIcon.icns"
MODULE_CACHE="${WORK_DIR}/module-cache"
SWIFT_BIN="/usr/bin/swift"

/bin/mkdir -p "${WORK_DIR}" "${RESOURCES_DIR}" "${MODULE_CACHE}"
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}"

cat > "${DRAW_SWIFT}" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments[1]
let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Unable to create bitmap context")
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.clear(CGRect(x: 0, y: 0, width: size, height: size))

let iconRect = CGRect(x: 64, y: 64, width: 896, height: 896)
let squircle = CGPath(roundedRect: iconRect, cornerWidth: 220, cornerHeight: 220, transform: nil)

context.saveGState()
context.addPath(squircle)
context.clip()

let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        color(10, 15, 22),
        color(13, 29, 36),
        color(18, 97, 111)
    ] as CFArray,
    locations: [0, 0.72, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
    end: CGPoint(x: iconRect.maxX, y: iconRect.minY),
    options: []
)

context.restoreGState()

context.addPath(squircle)
context.setStrokeColor(color(126, 236, 247, 0.36))
context.setLineWidth(12)
context.strokePath()

let center = CGPoint(x: 512, y: 512)
let globeRadius: CGFloat = 238
let globeRect = CGRect(
    x: center.x - globeRadius,
    y: center.y - globeRadius,
    width: globeRadius * 2,
    height: globeRadius * 2
)
let globePath = CGPath(ellipseIn: globeRect, transform: nil)

context.saveGState()
context.addPath(globePath)
context.clip()
context.setStrokeColor(color(118, 238, 248, 0.96))
context.setLineWidth(34)
context.setLineCap(.round)
context.setLineJoin(.round)

context.addEllipse(in: globeRect)
context.strokePath()

context.move(to: CGPoint(x: center.x - globeRadius + 22, y: center.y))
context.addLine(to: CGPoint(x: center.x + globeRadius - 22, y: center.y))
context.strokePath()

for longitudeWidth in [172.0, 318.0] {
    let longitudeRect = CGRect(
        x: center.x - longitudeWidth / 2,
        y: center.y - globeRadius,
        width: longitudeWidth,
        height: globeRadius * 2
    )
    context.addEllipse(in: longitudeRect)
    context.strokePath()
}
context.restoreGState()

context.setLineCap(.round)
context.setLineJoin(.round)
context.setStrokeColor(color(6, 12, 18, 0.88))
context.setLineWidth(110)
context.move(to: CGPoint(x: 318, y: 706))
context.addLine(to: CGPoint(x: 706, y: 318))
context.strokePath()

context.setStrokeColor(color(128, 244, 252))
context.setLineWidth(68)
context.move(to: CGPoint(x: 326, y: 698))
context.addLine(to: CGPoint(x: 698, y: 326))
context.strokePath()

guard let cgImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outputPath) as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
    fatalError("Unable to create PNG")
}

CGImageDestinationAddImage(destination, cgImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to write PNG")
}
SWIFT

echo "-> genero sorgente 1024x1024"
"${SWIFT_BIN}" "${DRAW_SWIFT}" "${SOURCE_PNG}"

/bin/rm -rf "${ICONSET}"
/bin/mkdir -p "${ICONSET}"

make_icon() {
    local pixels="$1"
    local name="$2"
    /usr/bin/sips -s format png -z "${pixels}" "${pixels}" "${SOURCE_PNG}" --out "${ICONSET}/${name}" >/dev/null
}

make_icon 16 "icon_16x16.png"
make_icon 32 "icon_16x16@2x.png"
make_icon 32 "icon_32x32.png"
make_icon 64 "icon_32x32@2x.png"
make_icon 128 "icon_128x128.png"
make_icon 256 "icon_128x128@2x.png"
make_icon 256 "icon_256x256.png"
make_icon 512 "icon_256x256@2x.png"
make_icon 512 "icon_512x512.png"
make_icon 1024 "icon_512x512@2x.png"

/usr/bin/iconutil -c icns "${ICONSET}" -o "${DEST_ICNS}"

echo "OK iconset: ${ICONSET}"
echo "OK icns: ${DEST_ICNS}"
