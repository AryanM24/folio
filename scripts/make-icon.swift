#!/usr/bin/env swift
// Renders Folio's app icon at every size macOS needs and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
//
// The geometry is the brand mark from brand/logo/folio-mark.svg, the same coordinates
// on a 64-unit tile, so the app icon, website and brand files can't drift apart. See
// brand/README.md for the construction.
//
// The art is full-bleed and opaque: macOS applies its own squircle mask and margins to
// icons like this. Art that brings its own transparent margins gets put on a grey tile.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Folio.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// A path from SVG-style points on the 64-unit tile (y grows downward, like the SVG).
func path(_ points: [(CGFloat, CGFloat)]) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for pt in points.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
    p.closeSubpath()
    return p
}

// brand/logo/folio-mark.svg: <path d="M20 16H40L46 22V24H28V30H40V38H28V48H20Z"/> and the fold.
let sheet = path([(20, 16), (40, 16), (46, 22), (46, 24), (28, 24), (28, 30), (40, 30), (40, 38), (28, 38), (28, 48), (20, 48)])
let fold = path([(40, 16), (40, 22), (46, 22)])

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Map the 64-unit tile onto the canvas, flipping y so SVG coordinates work as-is.
    let s = CGFloat(px) / 64
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)

    ctx.setFillColor(color(0x18181B))  // Eclipse
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))

    // Same transform as the SVG: scale 1.1 about the tile centre, glyph centre at x = 33.
    ctx.translateBy(x: 32, y: 32)
    ctx.scaleBy(x: 1.1, y: 1.1)
    ctx.translateBy(x: -33, y: -32)
    ctx.addPath(sheet)
    ctx.setFillColor(color(0xFCFCFC))  // Snow
    ctx.fillPath()
    ctx.addPath(fold)
    ctx.setFillColor(color(0x0485F7))  // Folio Blue
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appending(path: "icon_\(size)x\(size)@2x.png"))
}
print("wrote \(out.path)")
