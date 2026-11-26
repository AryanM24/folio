import AppKit
import PDFKit

/// Builds standard PDF annotations from what the user drew.
///
/// Only standard subtypes are used (Highlight, Ink, FreeText, Square, Line…), so the
/// results open and stay editable in Preview, Acrobat and browsers. All coordinates in
/// and out are PDF page space; PDFKit wants paths and points relative to the
/// annotation's bounds origin ("annotation space"), which this type takes care of.
enum AnnotationFactory {
    /// Who wrote the annotation, shown by other readers in comment lists.
    nonisolated static var authorName: String { NSFullUserName() }

    // MARK: Text markup

    /// One markup annotation per selected line, so highlights hug the text instead of
    /// covering the gaps between lines. Returns (page, annotation) pairs.
    static func markup(_ tool: AnnotationTool, for selection: PDFSelection, style: AnnotationStyle) -> [(PDFPage, PDFAnnotation)] {
        let subtype: PDFAnnotationSubtype =
            switch tool {
            case .underline: .underline
            case .strikeOut: .strikeOut
            default: .highlight
            }
        var result: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                let annotation = make(subtype, bounds: bounds, color: style.pdfColor)
                annotation.quadrilateralPoints = quad(for: bounds.size)
                result.append((page, annotation))
            }
        }
        return result
    }

    /// Quad points for a whole rect, in the order PDFKit documents: upper left, upper
    /// right, lower left, lower right.
    static func quad(for size: CGSize) -> [NSValue] {
        [CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height), .zero, CGPoint(x: size.width, y: 0)]
            .map { NSValue(point: $0) }
    }

    // MARK: Drawing

    /// A freehand stroke. `points` are page space; the bounds are padded by the stroke
    /// width so round caps aren't clipped.
    static func ink(points: [CGPoint], style: AnnotationStyle) -> PDFAnnotation? {
        guard let first = points.first else { return nil }
        let pad = style.lineWidth / 2 + 1
        let box = points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            .insetBy(dx: -pad, dy: -pad)
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first - box.origin)
        if points.count == 1 {
            path.line(to: first - box.origin + CGPoint(x: 0.01, y: 0))
        }
        for point in points.dropFirst() { path.line(to: point - box.origin) }
        let annotation = make(.ink, bounds: box, color: style.pdfColor)
        annotation.border = border(width: style.lineWidth)
        annotation.add(path)
        return annotation
    }

    /// Rectangle, ellipse, line or arrow spanning a drag from `start` to `end`.
    static func shape(_ tool: AnnotationTool, from start: CGPoint, to end: CGPoint, style: AnnotationStyle) -> PDFAnnotation {
        switch tool {
        case .line, .arrow:
            let pad = style.lineWidth * 4 + 2
            let box = Geometry.rect(from: start, to: end).insetBy(dx: -pad, dy: -pad)
            let annotation = make(.line, bounds: box, color: style.pdfColor)
            annotation.startPoint = start - box.origin
            annotation.endPoint = end - box.origin
            annotation.endLineStyle = tool == .arrow ? .openArrow : .none
            annotation.border = border(width: style.lineWidth)
            return annotation
        default:
            let box = Geometry.rect(from: start, to: end)
            let annotation = make(tool == .ellipse ? .circle : .square, bounds: box, color: style.pdfColor)
            annotation.border = border(width: style.lineWidth)
            return annotation
        }
    }

    /// A text box with placeholder text the user replaces in the inspector.
    static func textBox(in rect: CGRect, style: AnnotationStyle) -> PDFAnnotation {
        let annotation = make(.freeText, bounds: rect, color: .clear)
        annotation.contents = "Text"
        annotation.font = NSFont.systemFont(ofSize: style.fontSize)
        annotation.fontColor = style.pdfColor
        annotation.border = border(width: 0)
        return annotation
    }

    /// The default size of a text box created with a click instead of a drag.
    static func defaultTextBox(at point: CGPoint, fontSize: Double) -> CGRect {
        CGRect(x: point.x, y: point.y - fontSize * 1.6, width: 180, height: fontSize * 1.8)
    }

    /// A sticky note icon whose text opens in a popup in every reader.
    static func note(at point: CGPoint, style: AnnotationStyle) -> PDFAnnotation {
        let annotation = make(.text, bounds: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20), color: style.pdfColor)
        annotation.iconType = .comment
        annotation.contents = ""
        return annotation
    }

    // MARK: Helpers

    static func border(width: Double) -> PDFBorder {
        let border = PDFBorder()
        border.lineWidth = width
        return border
    }

    private static func make(_ subtype: PDFAnnotationSubtype, bounds: CGRect, color: NSColor) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.color = color
        annotation.userName = authorName
        annotation.modificationDate = Date()
        return annotation
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
