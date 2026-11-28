import CoreGraphics
import CoreImage
import Foundation

/// Vector shapes drawn with Core Graphics, like ``MarkupDrawing``.
nonisolated enum ShapeRenderer {
    /// The shape in layer space at `scale`, or `nil` when it draws nothing.
    static func image(_ shape: ShapeSpec, scale: Double) -> CIImage? {
        let bounds = bounds(of: shape)
        let outline = path(shape.geometry)
        var out: CIImage?
        if let fill = shape.fill, !shape.isLine {
            switch fill {
            case .solid(let color):
                out = LayerCompositor.draw(bounds, scale: scale) { ctx in
                    ctx.addPath(outline)
                    ctx.setFillColor(color.cgColor)
                    ctx.fillPath()
                }
            case .gradient:
                if let alpha = LayerCompositor.draw(
                    bounds, scale: scale,
                    { ctx in
                        ctx.addPath(outline)
                        ctx.fillPath()
                    })
                {
                    out = GradientRenderer.image(fill, extent: alpha.extent, scale: scale).applyingFilter(
                        "CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: alpha])
                }
            }
        }
        if let stroke = shape.stroke, stroke.width > 0,
            let stroked = LayerCompositor.draw(bounds, scale: scale, { ctx in drawStroke(shape.geometry, outline, stroke, in: ctx) })
        {
            out = out.map { stroked.composited(over: $0) } ?? stroked
        }
        return out
    }

    /// Everything the shape paints, in layer space.
    static func bounds(of shape: ShapeSpec) -> CGRect {
        let box = path(shape.geometry).boundingBoxOfPath
        guard !box.isNull else { return .null }
        var pad = 1.0
        if let stroke = shape.stroke {
            // Miter joins can poke out far past the path; heads stick out past the ends.
            pad += stroke.width * (stroke.join == .miter ? 5 : 1) / 2 + (shape.isLine ? headLength(stroke.width) : 0)
        }
        return box.insetBy(dx: -pad, dy: -pad)
    }

    /// The outline of `geometry` (for lines, the shaft), in layer space.
    static func path(_ geometry: ShapeSpec.Geometry) -> CGPath {
        let path = CGMutablePath()
        switch geometry {
        case .rectangle(let rect, let radius):
            let r = min(max(0, radius), min(rect.width, rect.height) / 2)
            path.addRoundedRect(in: rect.standardized, cornerWidth: r, cornerHeight: r)
        case .ellipse(let rect):
            path.addEllipse(in: rect.standardized)
        case .line(let from, let to, _, _):
            path.move(to: from)
            path.addLine(to: to)
        case .polygon(let rect, let sides):
            path.addLines(between: ring(rect, count: max(3, sides), inner: 1))
            path.closeSubpath()
        case .star(let rect, let points, let inner):
            path.addLines(between: ring(rect, count: max(2, points) * 2, inner: min(1, max(0.01, inner))))
            path.closeSubpath()
        case .speechBubble(let rect, let tail):
            let rect = rect.standardized
            let r = min(rect.width, rect.height) * 0.2
            let body = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            // The tail's base sits inside the body, a quarter of the way from the center.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let angle = Double(atan2(tail.y - center.y, tail.x - center.x))
            let half = min(rect.width, rect.height) * 0.12
            let base = CGPoint(x: center.x + cos(angle) * rect.width / 4, y: center.y + sin(angle) * rect.height / 4)
            let tip = CGMutablePath()
            tip.move(to: CGPoint(x: base.x - sin(angle) * half, y: base.y + cos(angle) * half))
            tip.addLine(to: tail)
            tip.addLine(to: CGPoint(x: base.x + sin(angle) * half, y: base.y - cos(angle) * half))
            tip.closeSubpath()
            path.addPath(body.union(tip))
        case .path(let vector):
            path.addPath(vector.cgPath)
        }
        return path
    }

    /// Polygon (inner = 1) and star vertices, the first pointing up.
    private static func ring(_ rect: CGRect, count: Int, inner: Double) -> [CGPoint] {
        let rect = rect.standardized
        return (0..<count).map { (i: Int) -> CGPoint in
            let angle: Double = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(count)
            let r: Double = inner < 1 && i % 2 == 1 ? inner : 1
            let rx: Double = rect.width / 2 * r, ry: Double = rect.height / 2 * r
            return CGPoint(x: rect.midX + cos(angle) * rx, y: rect.midY + sin(angle) * ry)
        }
    }

    private static func headLength(_ width: Double) -> Double { max(width * 4, 12) }

    private static func drawStroke(_ geometry: ShapeSpec.Geometry, _ outline: CGPath, _ stroke: StrokeSpec, in ctx: CGContext) {
        ctx.setLineWidth(stroke.width)
        ctx.setStrokeColor(stroke.color.cgColor)
        ctx.setFillColor(stroke.color.cgColor)
        let cap: CGLineCap =
            switch stroke.cap {
            case .butt: .butt
            case .round: .round
            case .square: .square
            }
        let join: CGLineJoin =
            switch stroke.join {
            case .miter: .miter
            case .round: .round
            case .bevel: .bevel
            }
        ctx.setLineCap(cap)
        ctx.setLineJoin(join)
        if !stroke.dash.isEmpty { ctx.setLineDash(phase: 0, lengths: stroke.dash.map { CGFloat(max(0.1, $0)) }) }
        guard case .line(let from, let to, let startHead, let endHead) = geometry else {
            ctx.addPath(outline)
            ctx.strokePath()
            return
        }
        let length = headLength(stroke.width)
        // Stop the shaft inside filled heads so the cap doesn't poke through the tip.
        func inset(_ point: CGPoint, toward other: CGPoint, _ head: ShapeSpec.ArrowHead) -> CGPoint {
            guard head == .closed || head == .curved else { return point }
            let angle = Double(atan2(other.y - point.y, other.x - point.x))
            return CGPoint(x: point.x + cos(angle) * length * 0.6, y: point.y + sin(angle) * length * 0.6)
        }
        ctx.move(to: inset(from, toward: to, startHead))
        ctx.addLine(to: inset(to, toward: from, endHead))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        drawHead(endHead, at: to, from: from, length: length, in: ctx)
        drawHead(startHead, at: from, from: to, length: length, in: ctx)
    }

    private static func drawHead(_ head: ShapeSpec.ArrowHead, at tip: CGPoint, from tail: CGPoint, length: Double, in ctx: CGContext) {
        guard head != .none else { return }
        let angle = Double(atan2(tip.y - tail.y, tip.x - tail.x))
        let spread = Double.pi / 7
        let left = CGPoint(x: tip.x - cos(angle - spread) * length, y: tip.y - sin(angle - spread) * length)
        let right = CGPoint(x: tip.x - cos(angle + spread) * length, y: tip.y - sin(angle + spread) * length)
        ctx.move(to: left)
        ctx.addLine(to: tip)
        ctx.addLine(to: right)
        switch head {
        case .open:
            ctx.strokePath()
        case .closed:
            ctx.closePath()
            ctx.fillPath()
        case .curved:
            let notch = CGPoint(x: tip.x - cos(angle) * length * 0.55, y: tip.y - sin(angle) * length * 0.55)
            ctx.addQuadCurve(to: left, control: notch)
            ctx.fillPath()
        case .none:
            break
        }
    }
}

nonisolated extension ShapeSpec {
    var isLine: Bool {
        if case .line = geometry { return true }
        return false
    }
}
