import AppKit
import PDFKit

/// Produces a new page from an existing one: same content, same boxes and rotation,
/// optionally with annotations burned into the content and extra drawing on top.
///
/// PDFKit can't edit a page's content stream, so every operation that changes what is
/// printed on the page (flattening, page numbers, watermarks, OCR text layers) rebuilds
/// the page and swaps it in. The original page object is left untouched, which makes
/// undo a simple swap back.
nonisolated enum PageRebuilder {
    /// Which annotations become part of the page content. The rest are copied over
    /// as live annotations.
    enum Burn {
        case none
        case all
        case formFields
        func includes(_ annotation: PDFAnnotation) -> Bool {
            switch self {
            case .none: false
            case .all: true
            case .formFields: annotation.type == PDFAnnotationSubtype.widget.name
            }
        }
    }

    /// Rebuilds `page`. `overlay` draws in PDF page space after the original content.
    static func rebuild(_ page: PDFPage, burn: Burn = .none, overlay: (CGContext) -> Void = { _ in }) -> PDFPage? {
        let media = page.bounds(for: .mediaBox)
        let annotations = page.annotations
        guard
            let rebuilt = PageFactory.render(
                mediaBox: media,
                draw: { context in
                    if let ref = page.pageRef { context.drawPDFPage(ref) }
                    for annotation in annotations where burn.includes(annotation) && annotation.shouldDisplay {
                        context.saveGState()
                        annotation.draw(with: .mediaBox, in: context)
                        context.restoreGState()
                    }
                    overlay(context)
                })
        else { return nil }
        copyGeometry(from: page, to: rebuilt)
        for annotation in annotations where !burn.includes(annotation) {
            // Popups belong to their parent note; PDFKit recreates them.
            guard annotation.type != PDFAnnotationSubtype.popup.name else { continue }
            rebuilt.addAnnotation(annotation.persistentCopy())
        }
        return rebuilt
    }

    /// Crop box and rotation, which `render` doesn't know about.
    static func copyGeometry(from source: PDFPage, to target: PDFPage) {
        let crop = source.bounds(for: .cropBox)
        if crop != source.bounds(for: .mediaBox) { target.setBounds(crop, for: .cropBox) }
        target.rotation = source.rotation
    }
}

/// Quartz text drawing without AppKit's graphics context, so it works in any
/// `CGContext` on any thread.
nonisolated enum TextDrawing {
    /// Draws one line of text centred on `center`, rotated by `angle` radians.
    static func draw(
        _ text: String,
        in context: CGContext,
        center: CGPoint,
        fontSize: CGFloat,
        color: CGColor,
        weight: NSFont.Weight = .regular,
        angle: CGFloat = 0
    ) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font, .foregroundColor: NSColor(cgColor: color) ?? .black,
                ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
