import CoreGraphics
import CoreText
import Foundation

/// Draws markup with Core Graphics. The same code paints the live overlay (inside a
/// SwiftUI `Canvas`) and bakes markup into saved files, so what you see is what saves.
nonisolated enum MarkupDrawing {
    /// Draw `items` into a y-down context. `transform` maps source pixels to the
    /// context's coordinates (``ImageGeometry/outputTransform`` scaled to the target).
    static func draw(_ items: [MarkupItem], in ctx: CGContext, transform: CGAffineTransform) {
        for item in items {
            ctx.saveGState()
            ctx.concatenate(transform)
            draw(item, in: ctx)
            ctx.restoreGState()
        }
    }

    private static func draw(_ item: MarkupItem, in ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(item.lineWidth)
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setFillColor(item.color.cgColor)
        switch item.kind {
        case .pen, .highlighter:
            if item.kind == .highlighter {
                // Translucent and flat-ended, like a real marker; multiply keeps text legible.
                ctx.setAlpha(0.4)
                ctx.setBlendMode(.multiply)
                ctx.setLineCap(.butt)
            }
            guard let first = item.points.first else { return }
            if item.points.count == 1 {
                let r = item.lineWidth / 2
                ctx.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
                return
            }
            ctx.addLines(between: item.points)
            ctx.strokePath()
        case .rectangle:
            ctx.stroke(item.rect)
        case .ellipse:
            ctx.strokeEllipse(in: item.rect)
        case .arrow:
            guard let tail = item.points.first, let head = item.points.last else { return }
            let angle = atan2(Double(head.y - tail.y), Double(head.x - tail.x))
            let length = max(item.lineWidth * 4, 12)
            let spread = Double.pi / 7
            // Stop the shaft inside the head so the round cap doesn't poke through the tip.
            let shaftEnd = CGPoint(x: head.x - cos(angle) * length * 0.6, y: head.y - sin(angle) * length * 0.6)
            ctx.move(to: tail)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()
            ctx.move(to: head)
            ctx.addLine(to: CGPoint(x: head.x - cos(angle - spread) * length, y: head.y - sin(angle - spread) * length))
            ctx.addLine(to: CGPoint(x: head.x - cos(angle + spread) * length, y: head.y - sin(angle + spread) * length))
            ctx.closePath()
            ctx.fillPath()
        case .text:
            guard let origin = item.points.first else { return }
            let font = CTFontCreateUIFontForLanguage(.system, item.fontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, item.fontSize, nil)
            let lineHeight = item.fontSize * 1.2
            // The context is y-down; flip glyphs back upright.
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for (index, line) in lines(item.text).enumerated() {
                let attributed = NSAttributedString(string: line, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: item.color.cgColor,
                ])
                let ctLine = CTLineCreateWithAttributedString(attributed)
                ctx.textPosition = CGPoint(x: origin.x, y: origin.y + Double(index) * lineHeight + CTFontGetAscent(font))
                CTLineDraw(ctLine, ctx)
            }
        }
    }

    /// Measured size of a text item, for selection and hit testing.
    static func textSize(_ text: String, fontSize: Double) -> CGSize {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let all = lines(text)
        let width = all.map { line in
            let attributed = NSAttributedString(string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
        }.max() ?? 0
        return CGSize(width: max(fontSize / 2, width), height: Double(all.count) * fontSize * 1.2)
    }

    private static func lines(_ text: String) -> [String] {
        let split = text.components(separatedBy: "\n")
        return split.isEmpty ? [""] : split
    }

    /// Markup as a transparent image of `size` pixels (y-down `transform` from source
    /// pixels), ready to composite over the rendered photo.
    static func image(_ items: [MarkupItem], size: CGSize, transform: CGAffineTransform) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard !items.isEmpty, width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(items, in: ctx, transform: transform)
        return ctx.makeImage()
    }
}
