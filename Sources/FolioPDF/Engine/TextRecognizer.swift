import AppKit
import PDFKit
import Vision

/// "Recognize Text": OCR with Vision, written back as an invisible text layer.
///
/// The page is rebuilt with its original content plus each recognised line drawn in
/// PDF text render mode 3 (invisible), sized and stretched to cover the words it
/// came from. The page looks exactly the same, but its text can now be selected,
/// copied, searched and extracted like any other PDF text, by Folio and by every
/// other PDF reader.
nonisolated enum TextRecognizer {
    /// One recognised line. `box` is normalised to the page's media box (0…1, origin
    /// bottom-left), which is what Vision returns for an image of the whole media box.
    struct Line: Sendable, Equatable {
        let text: String
        let box: CGRect
    }

    /// Two pixels per point is enough for Vision's accurate model on body text.
    static let scale: CGFloat = 2

    /// Recognises the text in `image`. Runs on Vision's own queues, off the caller.
    static func recognize(_ image: CGImage) async throws -> [Line] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return Line(text: text, box: CGRect(origin: box.origin, size: CGSize(width: box.width, height: box.height)))
        }
    }

    /// A copy of `page` with `lines` added as invisible, selectable text.
    static func addingTextLayer(to page: PDFPage, lines: [Line]) -> PDFPage? {
        let media = page.bounds(for: .mediaBox)
        return PageRebuilder.rebuild(page) { context in
            context.saveGState()
            context.setTextDrawingMode(.invisible)
            for line in lines {
                draw(line, in: context, media: media)
            }
            context.restoreGState()
        }
    }

    /// Draws one line so its glyphs span the recognised box: font size from the box
    /// height, then a horizontal scale so the width matches. Selection highlights then
    /// sit on top of the visible words.
    private static func draw(_ line: Line, in context: CGContext, media: CGRect) {
        let rect = CGRect(
            x: media.minX + line.box.minX * media.width,
            y: media.minY + line.box.minY * media.height,
            width: line.box.width * media.width,
            height: line.box.height * media.height
        )
        guard rect.height > 1, rect.width > 1 else { return }
        let font = NSFont.systemFont(ofSize: rect.height * 0.8)
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        guard width > 0 else { return }
        context.textMatrix = CGAffineTransform(scaleX: rect.width / width, y: 1)
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
        CTLineDraw(ctLine, context)
    }
}
