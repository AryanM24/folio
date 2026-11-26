import AppKit
import PDFKit

/// Prints text onto pages as real (vector, selectable) content: page numbers and
/// watermarks. Drawing happens in display space (see ``Geometry/displayToPage(crop:rotation:)``),
/// so the text is upright and at the visual bottom even on rotated pages.
nonisolated enum PageStamper {
    /// Where page numbers sit, measured from the visual bottom edge.
    static let numberBaseline: CGFloat = 24

    /// "3 of 12"-style label for page `index` (0-based) of `count`.
    static func pageLabel(index: Int, count: Int) -> String {
        "\(index + 1) of \(count)"
    }

    /// A copy of `page` with `label` centred at its visual bottom.
    static func numbered(_ page: PDFPage, label: String) -> PDFPage? {
        stamped(page) { context, size in
            TextDrawing.draw(
                label, in: context,
                center: CGPoint(x: size.width / 2, y: numberBaseline),
                fontSize: 10, color: CGColor(gray: 0.35, alpha: 1)
            )
        }
    }

    /// A copy of `page` with `text` across its middle, diagonal and translucent.
    static func watermarked(_ page: PDFPage, text: String) -> PDFPage? {
        stamped(page) { context, size in
            let diagonal = (size.width * size.width + size.height * size.height).squareRoot()
            // Bold glyphs average ~0.6 em, so this spans ~60 % of the diagonal at any length.
            let fontSize = max(12, diagonal / CGFloat(max(text.count, 1)))
            TextDrawing.draw(
                text, in: context,
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                fontSize: fontSize, color: CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 0.18),
                weight: .bold, angle: atan2(size.height, size.width)
            )
        }
    }

    /// Rebuilds `page`, handing `draw` a context in display space and the display size.
    private static func stamped(_ page: PDFPage, draw: @escaping (CGContext, CGSize) -> Void) -> PDFPage? {
        let crop = page.bounds(for: .cropBox)
        let transform = Geometry.displayToPage(crop: crop, rotation: page.rotation)
        let size = Geometry.displaySize(crop: crop, rotation: page.rotation)
        return PageRebuilder.rebuild(page) { context in
            context.saveGState()
            context.concatenate(transform)
            draw(context, size)
            context.restoreGState()
        }
    }
}
