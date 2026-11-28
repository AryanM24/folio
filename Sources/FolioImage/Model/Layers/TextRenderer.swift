import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Text layers through Core Text: styled runs, point or area text, text on a path, and
/// solid or gradient fills. The text's top-left sits at the layer origin.
nonisolated enum TextRenderer {
    /// The text in layer space at `scale`, or `nil` when it's empty.
    static func image(_ text: TextSpec, scale: Double) -> CIImage? {
        guard !text.string.isEmpty else { return nil }
        var override: CGColor?
        switch text.fill {
        case .solid(let color): override = color.cgColor
        case .gradient: override = CGColor(gray: 1, alpha: 1)
        case nil: break
        }
        guard
            let glyphs = LayerCompositor.draw(bounds(of: text), scale: scale, { ctx in draw(text, color: override, in: ctx) })
        else { return nil }
        guard case .gradient = text.fill, let fill = text.fill else { return glyphs }
        return GradientRenderer.image(fill, extent: glyphs.extent, scale: scale).applyingFilter(
            "CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: glyphs])
    }

    /// The laid-out size in layer pixels (the box for area text).
    static func size(of text: TextSpec) -> CGSize {
        if text.path != nil { return bounds(of: text).size }
        if let box = text.box { return box }
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter(text, color: nil), CFRange(location: 0, length: 0), nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), nil)
        // A hair wider than measured, so laying out in that width never wraps.
        return text.string.isEmpty ? .zero : CGSize(width: fit.width.rounded(.up) + 1, height: fit.height.rounded(.up) + 1)
    }

    /// What the text paints, in layer space.
    static func bounds(of text: TextSpec) -> CGRect {
        guard let path = text.path else { return CGRect(origin: .zero, size: size(of: text)) }
        let tallest = text.runs.map(\.size).max() ?? 0
        return path.cgPath.boundingBoxOfPath.insetBy(dx: -tallest * 1.5, dy: -tallest * 1.5)
    }

    // MARK: Layout

    // Core Text can't draw strikethrough; runs that want it carry their index under this key.
    private static let strikeKey = NSAttributedString.Key("FolioStrikethrough")

    private static func attributed(_ text: TextSpec, color override: CGColor?) -> NSAttributedString {
        var alignment: CTTextAlignment =
            switch text.alignment {
            case .left: .left
            case .center: .center
            case .right: .right
            case .justified: .justified
            }
        var multiple = CGFloat(max(0.1, text.lineHeight))
        let style = withUnsafeBytes(of: &alignment) { a in
            withUnsafeBytes(of: &multiple) { m in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: a.count, value: a.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: m.count, value: m.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let out = NSMutableAttributedString()
        for (index, run) in text.runs.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font(run),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): override ?? run.color.cgColor,
                NSAttributedString.Key(kCTKernAttributeName as String): run.tracking / 1000 * run.size,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            ]
            if run.underline {
                attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
            }
            if run.strikethrough { attributes[strikeKey] = index }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return out
    }

    /// The run's font by PostScript name; Core Text substitutes a default when it's missing.
    private static func font(_ run: TextRun) -> CTFont { CTFontCreateWithName(run.fontName as CFString, max(1, run.size), nil) }

    private static func framesetter(_ text: TextSpec, color: CGColor?) -> CTFramesetter {
        CTFramesetterCreateWithAttributedString(attributed(text, color: color))
    }

    /// Draw into a y-down context in layer coordinates.
    private static func draw(_ text: TextSpec, color: CGColor?, in ctx: CGContext) {
        if let path = text.path {
            drawOnPath(text, path, color: color, in: ctx)
            return
        }
        let size = size(of: text)
        let frame = CTFramesetterCreateFrame(
            framesetter(text, color: color), CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(origin: .zero, size: size), transform: nil),
            nil)
        ctx.saveGState()
        // Core Text lays out y up; flip within the text's box.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        strikethrough(frame, text, color: color, in: ctx)
        ctx.restoreGState()
    }

    private static func strikethrough(_ frame: CTFrame, _ text: TextSpec, color: CGColor?, in ctx: CGContext) {
        guard text.runs.contains(where: \.strikethrough) else { return }
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(lines, origins) {
            for glyphRun in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attributes = CTRunGetAttributes(glyphRun) as NSDictionary
                guard let index = attributes[strikeKey.rawValue] as? Int, text.runs.indices.contains(index) else { continue }
                let run = text.runs[index]
                let font = font(run)
                var position = CGPoint.zero
                CTRunGetPositions(glyphRun, CFRange(location: 0, length: 1), &position)
                let width = CTRunGetTypographicBounds(glyphRun, CFRange(location: 0, length: 0), nil, nil, nil)
                let thickness = max(1, CTFontGetUnderlineThickness(font))
                ctx.setFillColor(color ?? run.color.cgColor)
                ctx.fill(
                    CGRect(
                        x: origin.x + position.x, y: origin.y + CTFontGetXHeight(font) / 2 - thickness / 2, width: width,
                        height: thickness))
            }
        }
    }

    /// One line of glyphs, each centered on the path and turned to follow it, baseline on
    /// the path. Alignment places the line along the path.
    private static func drawOnPath(_ text: TextSpec, _ path: VectorPath, color: CGColor?, in ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(attributed(text, color: color))
        let points = polyline(path)
        guard points.count > 1 else { return }
        var distances = [0.0]
        for i in 1..<points.count {
            distances.append(distances[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let total = distances.last!, width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let start: Double =
            switch text.alignment {
            case .left, .justified: 0
            case .center: (total - width) / 2
            case .right: total - width
            }
        for glyphRun in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(glyphRun)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            let all = CFRange(location: 0, length: 0)
            CTRunGetGlyphs(glyphRun, all, &glyphs)
            CTRunGetPositions(glyphRun, all, &positions)
            CTRunGetAdvances(glyphRun, all, &advances)
            let attributes = CTRunGetAttributes(glyphRun) as NSDictionary
            let fontValue = attributes[kCTFontAttributeName as String]
            let font = fontValue.map { $0 as! CTFont } ?? CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let fill = attributes[kCTForegroundColorAttributeName as String].map { $0 as! CGColor } ?? CGColor(gray: 0, alpha: 1)
            for i in 0..<count {
                let middle: Double = start + Double(positions[i].x + advances[i].width / 2)
                guard middle >= 0, middle <= total, let segment = distances.lastIndex(where: { $0 <= middle }) else { continue }
                let next = min(segment + 1, points.count - 1)
                let a = points[segment], b = points[next]
                let length = max(1e-6, distances[next] - distances[segment])
                let f = min(1, (middle - distances[segment]) / length)
                ctx.saveGState()
                ctx.translateBy(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                ctx.rotate(by: atan2(b.y - a.y, b.x - a.x))
                ctx.scaleBy(x: 1, y: -1)
                ctx.setFillColor(fill)
                CTFontDrawGlyphs(font, [glyphs[i]], [CGPoint(x: -advances[i].width / 2, y: 0)], 1, ctx)
                ctx.restoreGState()
            }
        }
    }

    /// The path as points, curves split into short segments.
    private static func polyline(_ path: VectorPath) -> [CGPoint] {
        var points: [CGPoint] = [], first: CGPoint?
        let steps = 24
        for element in path.elements {
            let from = points.last ?? .zero
            switch element {
            case .move(let p):
                if points.isEmpty { points.append(p) }
                first = p
            case .line(let p):
                points.append(p)
            case .quad(let p, let c):
                for s in 1...steps {
                    let t = Double(s) / Double(steps), u = 1 - t
                    points.append(
                        CGPoint(x: u * u * from.x + 2 * u * t * c.x + t * t * p.x, y: u * u * from.y + 2 * u * t * c.y + t * t * p.y))
                }
            case .curve(let p, let c1, let c2):
                for s in 1...steps {
                    let t = Double(s) / Double(steps), u = 1 - t
                    let x = u * u * u * from.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x
                    let y = u * u * u * from.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y
                    points.append(CGPoint(x: x, y: y))
                }
            case .close:
                if let first { points.append(first) }
            }
        }
        return points
    }
}
