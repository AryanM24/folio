import AppKit
import FolioKit
import PDFKit

/// Draws the selection outline, resize handles and live tool previews above the PDF.
///
/// It is a plain view on top of `PDFView` that ignores the mouse (`hitTest` returns
/// nil), so PDFKit keeps all interaction. Nothing drawn here is ever part of the
/// document: a preview becomes an annotation only when the gesture ends.
final class CanvasOverlay: NSView {
    weak var host: FolioPDFView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    /// `scripts/snapshot.sh` captures windows by asking views to draw themselves, which
    /// misses PDFKit's asynchronously rendered page tiles. In that mode only, the
    /// overlay paints the visible pages itself so snapshots show real content.
    private static let paintsPagesForSnapshots = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT_DIR"] != nil

    override func draw(_ dirtyRect: NSRect) {
        guard let host else { return }
        if Self.paintsPagesForSnapshots, let context = NSGraphicsContext.current?.cgContext {
            for page in host.visiblePages {
                let frame = rect(page.bounds(for: .cropBox), on: page, host: host)
                context.saveGState()
                context.setFillColor(.white)
                context.fill(frame)
                context.translateBy(x: frame.minX, y: frame.minY)
                context.scaleBy(x: host.scaleFactor, y: host.scaleFactor)
                page.draw(with: .cropBox, to: context)
                context.restoreGState()
            }
        }
        if let annotation = host.selection, let page = annotation.page {
            drawSelection(of: annotation, rect: rect(annotation.bounds, on: page, host: host))
        }
        guard let gesture = host.liveGesture else { return }
        let style = host.model?.style(for: host.liveTool) ?? .defaults(for: host.liveTool)
        switch gesture {
        case .ink(let page, let points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: point(first, on: page, host: host))
            for point in points.dropFirst() { path.line(to: self.point(point, on: page, host: host)) }
            path.lineWidth = style.lineWidth * host.scaleFactor
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            style.pdfColor.setStroke()
            path.stroke()
        case .rect(let page, let start, let end):
            drawPreview(
                from: point(start, on: page, host: host), to: point(end, on: page, host: host), style: style, scale: host.scaleFactor)
        case .move, .resize:
            break
        }
    }

    private func drawPreview(from a: CGPoint, to b: CGPoint, style: AnnotationStyle, scale: CGFloat) {
        let box = Geometry.rect(from: a, to: b)
        let tool = host?.liveTool ?? .select
        let path: NSBezierPath
        switch tool {
        case .ellipse:
            path = NSBezierPath(ovalIn: box)
        case .line, .arrow:
            path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
        case .redact:
            NSColor.black.withAlphaComponent(0.75).setFill()
            box.fill()
            path = NSBezierPath(rect: box)
            NSColor(Hero.danger).setStroke()
            path.lineWidth = 1.5
            path.stroke()
            return
        case .textBox:
            path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.lineWidth = 1
            NSColor(Hero.accent).setStroke()
            path.stroke()
            return
        default:
            path = NSBezierPath(rect: box)
        }
        path.lineWidth = style.lineWidth * scale
        style.pdfColor.setStroke()
        path.stroke()
    }

    /// Accent outline with white, accent-ringed handles, as in HeroUI's focus style.
    private func drawSelection(of annotation: PDFAnnotation, rect: CGRect) {
        let outline = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
        outline.lineWidth = 1.5
        NSColor(Hero.accent).setStroke()
        outline.stroke()
        guard AnnotationKind(annotation).isResizable else { return }
        for handle in Handle.allCases {
            let center = handle.point(in: rect)
            let dot = NSBezierPath(ovalIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            NSColor.white.setFill()
            dot.fill()
            dot.lineWidth = 1.5
            NSColor(Hero.accent).setStroke()
            dot.stroke()
        }
    }

    private func rect(_ rect: CGRect, on page: PDFPage, host: PDFView) -> CGRect {
        convert(host.convert(rect, from: page), from: host)
    }

    private func point(_ point: CGPoint, on page: PDFPage, host: PDFView) -> CGPoint {
        convert(host.convert(point, from: page), from: host)
    }
}
