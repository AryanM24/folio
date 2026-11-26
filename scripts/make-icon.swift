#!/usr/bin/env swift
// Renders Folio's app icon at every size macOS needs and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
//
// Drawn in code so the icon is reviewable in a diff and needs no design tools.
// The art is full-bleed and opaque: macOS 26 applies its own squircle mask to icons
// like this, while art with its own transparent margins gets placed on a grey tile.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Folio.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Background: HeroUI "eclipse", full bleed.
    ctx.setFillColor(color(0x18181B).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    // Scale the artwork up a little to fill the larger canvas.
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 1.18, y: 1.18)
    ctx.translateBy(x: -512, y: -512)

    // Page with a folded corner.
    let page = CGMutablePath()
    page.move(to: CGPoint(x: 330, y: 250))
    page.addLine(to: CGPoint(x: 330, y: 774))
    page.addLine(to: CGPoint(x: 582, y: 774))
    page.addLine(to: CGPoint(x: 694, y: 662))
    page.addLine(to: CGPoint(x: 694, y: 250))
    page.closeSubpath()
    ctx.addPath(page)
    ctx.setFillColor(color(0xFCFCFC).cgColor)
    ctx.fillPath()

    // The fold, in HeroUI accent.
    let fold = CGMutablePath()
    fold.move(to: CGPoint(x: 582, y: 774))
    fold.addLine(to: CGPoint(x: 582, y: 662))
    fold.addLine(to: CGPoint(x: 694, y: 662))
    fold.closeSubpath()
    ctx.addPath(fold)
    ctx.setFillColor(color(0x0485F7).cgColor)
    ctx.fillPath()

    // Three text lines.
    ctx.setFillColor(color(0x18181B, 0.85).cgColor)
    for (i, w) in [250.0, 300, 200].enumerated() {
        let y = 560 - CGFloat(i) * 70
        ctx.addPath(CGPath(roundedRect: CGRect(x: 386, y: y, width: w, height: 28), cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appending(path: "icon_\(size)x\(size)@2x.png"))
}
print("wrote \(out.path)")
