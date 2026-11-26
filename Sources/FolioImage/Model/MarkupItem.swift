import CoreGraphics
import Foundation

/// A shape, stroke or label drawn on top of the image.
///
/// Points are in *source pixel* coordinates (top-left origin) of the original image,
/// so markup stays glued to the content when the image is later rotated, flipped,
/// straightened or cropped, as if it had been painted on.
nonisolated struct MarkupItem: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case pen, highlighter, arrow, rectangle, ellipse, text
    }

    var id = UUID()
    var kind: Kind
    /// Pen/highlighter: the stroke. Arrow: tail, head. Rectangle/ellipse: two corners.
    /// Text: the top-left of the first line.
    var points: [CGPoint]
    var color: RGBA
    /// Stroke width in source pixels.
    var lineWidth: Double
    var text = ""
    /// Font size in source pixels.
    var fontSize = 48.0

    /// The rectangle spanned by two-point shapes.
    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .null }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Bounds in source pixels, including stroke width.
    var bounds: CGRect {
        switch kind {
        case .text:
            let origin = points.first ?? .zero
            return CGRect(origin: origin, size: MarkupDrawing.textSize(text, fontSize: fontSize))
        default:
            guard let first = points.first else { return .null }
            var box = CGRect(origin: first, size: .zero)
            for p in points { box = box.union(CGRect(origin: p, size: .zero)) }
            let pad = lineWidth / 2 + (kind == .arrow ? lineWidth * 2 : 0)
            return box.insetBy(dx: -pad, dy: -pad)
        }
    }

    /// Whether a point (source pixels) is on the item, within `tolerance` pixels.
    func contains(_ point: CGPoint, tolerance: Double) -> Bool {
        switch kind {
        case .text, .rectangle, .ellipse:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .pen, .highlighter, .arrow:
            let reach = tolerance + lineWidth / 2
            if points.count == 1, let p = points.first { return hypot(p.x - point.x, p.y - point.y) <= reach }
            return zip(points, points.dropFirst()).contains { a, b in
                Self.distance(from: point, toSegment: a, b) <= reach
            }
        }
    }

    func offset(by delta: CGSize) -> MarkupItem {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// An sRGB color that encodes as four numbers.
nonisolated struct RGBA: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let red = RGBA(red: 1, green: 0.23, blue: 0.19)
    static let white = RGBA(red: 1, green: 1, blue: 1)

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// `#RRGGBB`, the form designers paste.
    var hex: String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
