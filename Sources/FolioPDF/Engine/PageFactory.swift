import AppKit
import PDFKit

/// Makes new pages: blank ones, pages from images, and pages drawn with Quartz.
///
/// Everything that produces page content funnels through ``render(mediaBox:draw:)``,
/// which records Quartz drawing into a one-page PDF. That keeps vector content vector
/// (text stays selectable) and gives one place to reason about coordinates: drawing
/// happens in PDF page space, origin bottom-left, in points.
nonisolated enum PageFactory {
    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)

    /// US Letter where people use it, A4 everywhere else.
    static var defaultPaper: CGRect {
        Locale.current.measurementSystem == .us ? letter : a4
    }

    /// A one-page PDF drawn by `draw`, returned as a page ready to insert elsewhere.
    static func render(mediaBox: CGRect, draw: (CGContext) -> Void) -> PDFPage? {
        let data = NSMutableData()
        var box = mediaBox
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return nil }
        context.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(rect: mediaBox)] as CFDictionary)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// An empty white page.
    static func blankPage(size: CGRect = defaultPaper) -> PDFPage? {
        render(mediaBox: size) { _ in }
    }

    /// The content of a new, untitled PDF.
    static func blankDocument() -> PDFDocument {
        let document = PDFDocument()
        if let page = blankPage() { document.insert(page, at: 0) }
        return document
    }

    /// A page showing `image` at its natural size (72 dpi points), or fitted to
    /// `fitting` with a margin when given (for "Insert pages from image" into a document
    /// whose pages have a fixed paper size).
    static func page(for image: CGImage, fitting paper: CGRect? = nil) -> PDFPage? {
        let natural = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let paper else {
            return render(mediaBox: natural) { $0.draw(image, in: natural) }
        }
        let margin: CGFloat = 36
        let target = Geometry.aspectFit(natural.size, in: paper.insetBy(dx: margin, dy: margin))
        return render(mediaBox: paper) { context in
            context.interpolationQuality = .high
            context.draw(image, in: target)
        }
    }

    /// `paper` turned to landscape for wide images, portrait for tall ones.
    static func paper(_ paper: CGRect, orientedFor image: CGImage) -> CGRect {
        let wide = image.width > image.height
        return wide == (paper.width > paper.height) ? paper : CGRect(x: 0, y: 0, width: paper.height, height: paper.width)
    }

    /// Loads the first frame of an image file, upright. Photos store their rotation
    /// as EXIF orientation, which only the thumbnail path applies, so we ask for a
    /// "thumbnail" at full size.
    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
