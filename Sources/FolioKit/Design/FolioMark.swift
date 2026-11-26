public import SwiftUI

// The Folio mark and wordmark as SwiftUI shapes.
//
// Same coordinates as brand/logo/*.svg and scripts/make-icon.swift (a 64-unit tile for the
// mark, an 84×33 box for the wordmark), so the app, the icon and the brand files never
// drift. See brand/README.md for the construction.

/// The folded F: the sheet, without the fold.
public struct FolioGlyphSheet: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        Self.points(
            [(20, 16), (40, 16), (46, 22), (46, 24), (28, 24), (28, 30), (40, 30), (40, 38), (28, 38), (28, 48), (20, 48)], in: rect)
    }

    /// Maps points on the 64-unit tile into `rect`, with the brand's 1.1× scale about the centre.
    static func points(_ pts: [(CGFloat, CGFloat)], in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 64
        func map(_ p: (CGFloat, CGFloat)) -> CGPoint {
            CGPoint(x: rect.minX + (32 + (p.0 - 33) * 1.1) * unit, y: rect.minY + (32 + (p.1 - 32) * 1.1) * unit)
        }
        var path = Path()
        path.move(to: map(pts[0]))
        for p in pts.dropFirst() { path.addLine(to: map(p)) }
        path.closeSubpath()
        return path
    }
}

/// The folded corner of the F.
public struct FolioGlyphFold: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        FolioGlyphSheet.points([(40, 16), (40, 22), (46, 22)], in: rect)
    }
}

/// The app-icon mark: Eclipse tile, Snow sheet, Folio Blue fold.
///
/// On dark backgrounds the Eclipse tile gets a hairline edge (brand/README.md, Color),
/// so the mark never dissolves into a dark sidebar.
public struct FolioMark: View {
    @Environment(\.colorScheme) private var scheme
    public init() {}
    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).fill(Color(hex: 0x18181B))
                if scheme == .dark {
                    RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, side / 64))
                }
                FolioGlyphSheet().fill(Color(hex: 0xFCFCFC))
                FolioGlyphFold().fill(Hero.accent)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Folio")
    }
}

/// The geometric "folio" wordmark. Takes the foreground style; the i's dot stays Folio Blue.
public struct FolioWordmark: View {
    public init() {}
    public var body: some View {
        GeometryReader { geo in
            let k = min(geo.size.width / 84, geo.size.height / 33)
            ZStack(alignment: .topLeading) {
                WordmarkStrokes()
                    .stroke(style: StrokeStyle(lineWidth: 5 * k, lineCap: .butt))
                Rectangle()
                    .fill(Hero.accent)
                    .frame(width: 5 * k, height: 5 * k)
                    .offset(x: 54 * k)
            }
            .frame(width: 84 * k, height: 33 * k, alignment: .topLeading)
        }
        .aspectRatio(84 / 33, contentMode: .fit)
        .accessibilityLabel("Folio")
    }
}

/// The wordmark's strokes in an 84×33 box.
private struct WordmarkStrokes: Shape {
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width / 84, rect.height / 33)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var path = Path()
        // f
        path.move(to: p(5.5, 32))
        path.addLine(to: p(5.5, 10.5))
        path.addArc(center: p(13.5, 10.5), radius: 8 * k, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: p(16, 2.5))
        path.move(to: p(1, 14.5))
        path.addLine(to: p(14, 14.5))
        // o
        path.addEllipse(in: CGRect(origin: p(21.5, 14.5), size: CGSize(width: 15 * k, height: 15 * k)))
        // l
        path.move(to: p(45.5, 0))
        path.addLine(to: p(45.5, 32))
        // i
        path.move(to: p(56.5, 12))
        path.addLine(to: p(56.5, 32))
        // o
        path.addEllipse(in: CGRect(origin: p(66.5, 14.5), size: CGSize(width: 15 * k, height: 15 * k)))
        return path
    }
}
