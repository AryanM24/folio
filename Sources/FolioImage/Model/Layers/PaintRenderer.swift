import CoreGraphics
import CoreImage
import Synchronization

/// Paint layers: the baked raster, then each stroke since the bake stamped as round dabs.
///
/// Like Photoshop, flow is how much each dab adds and opacity caps the whole stroke
/// (each stroke draws into its own transparency layer); pressure scales the dab size;
/// eraser strokes remove pixels (destination-out).
nonisolated enum PaintRenderer {
    /// The paint in layer space at `scale`, or `nil` when there's nothing to draw.
    static func image(_ paint: PaintSpec, assets: any AssetStore, scale: Double) -> CIImage? {
        if let hit = cache.withLock({ $0.first { $0.paint == paint && $0.scale == scale }?.image }) { return hit }
        let baked = paint.baked.flatMap { placed in LayerCompositor.decodedCG(placed.asset, assets: assets).map { (placed.rect, $0) } }
        let image = LayerCompositor.draw(bounds(of: paint, assets: assets), scale: scale) { ctx in
            if let (rect, cg) = baked {
                ctx.saveGState()
                // Bitmaps draw y up; flip them upright in the y-down layer space.
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cg, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            }
            for stroke in paint.strokes { draw(stroke, in: ctx) }
        }
        if let image {
            // Repainting thousands of dabs per frame would make every other edit slow.
            cache.withLock { cache in
                cache.insert((paint, scale, image), at: 0)
                if cache.count > 8 { cache.removeLast() }
            }
        }
        return image
    }

    /// The baked raster and every dab, in layer space.
    static func bounds(of paint: PaintSpec, assets: any AssetStore) -> CGRect {
        paint.strokes.reduce(paint.baked?.rect ?? .null) { rect, stroke in
            let r = stroke.size / 2 + 1
            return stroke.points.reduce(rect) { $0.union(CGRect(x: $1.location.x - r, y: $1.location.y - r, width: r * 2, height: r * 2)) }
        }
    }

    private static let cache = Mutex<[(paint: PaintSpec, scale: Double, image: CIImage)]>([])

    private static func draw(_ stroke: BrushStroke, in ctx: CGContext) {
        guard let first = stroke.points.first else { return }
        ctx.saveGState()
        ctx.setAlpha(min(1, max(0, stroke.opacity)))
        if stroke.isEraser { ctx.setBlendMode(.destinationOut) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let color = stroke.isEraser ? RGBA(red: 0, green: 0, blue: 0) : stroke.color
        let flow = min(1, max(0, stroke.flow)) * color.alpha
        let dabColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: flow)
        let clear = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 0)
        let hardness = min(1, max(0, stroke.hardness))
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let gradient = space.flatMap {
            CGGradient(colorsSpace: $0, colors: [dabColor, dabColor, clear] as CFArray, locations: [0, hardness, 1])
        }
        func dab(_ at: CGPoint, pressure: Double) {
            let r = max(0.5, stroke.size * min(1, max(0.05, pressure)) / 2)
            if hardness >= 0.99 || gradient == nil {
                ctx.setFillColor(dabColor)
                ctx.fillEllipse(in: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2))
            } else if let gradient {
                ctx.drawRadialGradient(gradient, startCenter: at, startRadius: 0, endCenter: at, endRadius: r, options: [])
            }
        }
        dab(first.location, pressure: first.pressure)
        // Dabs every 15 % of the brush diameter read as a continuous line.
        func spacing(_ pressure: Double) -> Double { max(0.5, stroke.size * max(0.05, pressure) * 0.15) }
        var carry = spacing(first.pressure)
        for (a, b) in zip(stroke.points, stroke.points.dropFirst()) {
            let length = hypot(b.location.x - a.location.x, b.location.y - a.location.y)
            var t = carry
            while t < length {
                let f = t / length
                let pressure = a.pressure + (b.pressure - a.pressure) * f
                dab(
                    CGPoint(x: a.location.x + (b.location.x - a.location.x) * f, y: a.location.y + (b.location.y - a.location.y) * f),
                    pressure: pressure)
                t += spacing(pressure)
            }
            carry = t - length
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
