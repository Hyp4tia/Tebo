// make-icon.swift — draws the SuperClean app icon at 1024 px.
//
// WHY a generator instead of a committed PNG: macOS asks for many sizes, and adjusting the mark
// should be a one-line change here plus a re-run of scripts/make-icon.sh. Drawing is done with
// AppKit/CoreGraphics so no external image tool is needed, and the broom is drawn from scratch
// rather than pulled from SF Symbols (whose set varies by macOS version).
//
// Usage: swift make-icon.swift <output.png>
//        (scripts/make-icon.sh slices it into every size and builds SuperClean.icns)

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let side = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("could not allocate the icon bitmap\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let context = NSGraphicsContext.current?.cgContext else {
    FileHandle.standardError.write(Data("no graphics context\n".utf8))
    exit(1)
}

let bounds = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
let inset: CGFloat = 24
let plate = bounds.insetBy(dx: inset, dy: inset)
let P = plate.width
let cornerRadius = P * 0.2237 // macOS squircle proportions

// MARK: Plate

let platePath = CGPath(roundedRect: plate, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
context.saveGState()
context.addPath(platePath)
context.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.22, green: 0.85, blue: 0.62, alpha: 1.0), // mint
        CGColor(red: 0.05, green: 0.55, blue: 0.90, alpha: 1.0)  // sky
    ] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: plate.minX, y: plate.maxY),
    end: CGPoint(x: plate.maxX, y: plate.minY),
    options: []
)
context.restoreGState()

// A hairline inner rim instead of an old-school gloss highlight: reads as glass, not as a stripe.
context.saveGState()
context.addPath(platePath)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
context.setLineWidth(P * 0.008)
context.strokePath()
context.restoreGState()

func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
    // Four-pointed star: a diamond with pinched waists, so it reads as a clean sparkle.
    let path = CGMutablePath()
    let waist = radius * 0.14
    path.move(to: CGPoint(x: center.x, y: center.y + radius))
    path.addQuadCurve(
        to: CGPoint(x: center.x + radius, y: center.y),
        control: CGPoint(x: center.x + waist, y: center.y + waist)
    )
    path.addQuadCurve(
        to: CGPoint(x: center.x, y: center.y - radius),
        control: CGPoint(x: center.x + waist, y: center.y - waist)
    )
    path.addQuadCurve(
        to: CGPoint(x: center.x - radius, y: center.y),
        control: CGPoint(x: center.x - waist, y: center.y - waist)
    )
    path.addQuadCurve(
        to: CGPoint(x: center.x, y: center.y + radius),
        control: CGPoint(x: center.x - waist, y: center.y + waist)
    )
    path.closeSubpath()
    return path
}

// The mark sits above and right of the plate centre: the brush end carries more visual weight, so
// centring the geometry leaves the brush crowding the lower-left corner.
let markCenter = CGPoint(x: plate.midX + P * 0.030, y: plate.midY + P * 0.035)

let totalLength = P * 0.54
let handleThickness = P * 0.054
let bristleLength = P * 0.185
let bristleSpread = P * 0.215
let brushX = -totalLength / 2
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 0.97)
// Deep teal for the ferrule: white-on-white structures blur into one blob at 32 px, a darker
// material between handle and bristles keeps the tool legible when it is tiny.
let ferruleColor = CGColor(red: 0.04, green: 0.32, blue: 0.46, alpha: 0.95)

context.saveGState()
// Local frame: broom lies along the x-axis with the brush at -x, then the whole mark is tilted so
// the handle runs lower-left to upper-right and the brush sweeps down-left.
context.translateBy(x: markCenter.x, y: markCenter.y)
context.rotate(by: .pi / 4)
context.setShadow(
    offset: CGSize(width: 0, height: -P * 0.010),
    blur: P * 0.030,
    color: CGColor(red: 0, green: 0.18, blue: 0.28, alpha: 0.30)
)

// Bristles first: a fan of separate strokes, so it reads as a brush at small sizes instead of a
// solid trapezoid. Near-constant opacity — a wide alpha range reads as an accidental duplicate
// layer rather than as depth.
let bristleCount = 9
context.setLineCap(.round)
for index in 0..<bristleCount {
    let t = CGFloat(index) / CGFloat(bristleCount - 1) - 0.5        // -0.5 … 0.5
    let startY = t * bristleSpread * 0.60
    let endY = t * bristleSpread * 1.26
    // Outer bristles are shorter, giving the brush a rounded silhouette.
    let length = bristleLength * (1 - 0.20 * abs(t) * 2)
    context.setStrokeColor(CGColor(red: 0.96, green: 0.99, blue: 1.0, alpha: 0.88))
    context.setLineWidth(P * 0.034)
    // Start under the ferrule so the round caps never poke out above it.
    context.move(to: CGPoint(x: brushX - P * 0.016, y: startY))
    context.addLine(to: CGPoint(x: brushX - length, y: endY))
    context.strokePath()
}

// Handle: a capsule whose end runs under the ferrule, so the two shapes read as one tool.
context.setFillColor(white)
let handleRect = CGRect(
    x: brushX - P * 0.012, y: -handleThickness / 2,
    width: totalLength, height: handleThickness
)
context.addPath(CGPath(roundedRect: handleRect, cornerWidth: handleThickness / 2, cornerHeight: handleThickness / 2, transform: nil))
context.fillPath()

// Ferrule: a darker band that hides the joint, anchors the bristles, and separates them from the
// handle at small sizes. Slightly wider than the bristle fan so the tool does not look flimsy.
context.setFillColor(ferruleColor)
let ferrule = CGRect(
    x: brushX - P * 0.032, y: -bristleSpread * 0.46,
    width: P * 0.050, height: bristleSpread * 0.92
)
context.addPath(CGPath(roundedRect: ferrule, cornerWidth: P * 0.016, cornerHeight: P * 0.016, transform: nil))
context.fillPath()
context.restoreGState()

// MARK: Sparkle
// One sparkle, clear of the brush: it says "cleaned" without colliding with the tool's silhouette.

context.setShadow(
    offset: CGSize(width: 0, height: -P * 0.006),
    blur: P * 0.018,
    color: CGColor(red: 0, green: 0.18, blue: 0.28, alpha: 0.22)
)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.93))
context.addPath(sparklePath(
    center: CGPoint(x: plate.midX - P * 0.300, y: plate.midY + P * 0.155),
    radius: P * 0.068
))
context.fillPath()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG encoding failed\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("wrote \(outputPath) (\(side)px)")
} catch {
    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
    exit(1)
}
