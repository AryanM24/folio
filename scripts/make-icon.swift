#!/usr/bin/env swift
// Renders Folio's app icon at every size macOS needs and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
//
// Drawn in code so the icon is reviewable in a diff and needs no design tools.
// Geometry follows Apple's macOS icon grid: an 824 pt rounded square centred on a
// 1024 pt canvas, corner radius ≈ 185 pt.

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

    // Tile: HeroUI "eclipse" with a soft drop shadow, like system icons.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(color(0x18181B).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

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
