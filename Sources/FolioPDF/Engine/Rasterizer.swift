import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Turns pages into bitmaps, and bitmaps into PNG or JPEG bytes.
nonisolated enum Rasterizer {
    /// Renders the page's media box unrotated, in page space, at `scale` pixels per
    /// point, with annotations drawn in. Used where pixels must line up with page
    /// coordinates: redaction and OCR.
    static func raster(_ page: PDFPage, scale: CGFloat, annotations: Bool = true, after: (CGContext) -> Void = { _ in }) -> CGImage? {
        let media = page.bounds(for: .mediaBox)
        let width = Int((media.width * scale).rounded(.up))
        let height = Int((media.height * scale).rounded(.up))
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -media.minX, y: -media.minY)
        if let ref = page.pageRef { context.drawPDFPage(ref) }
        if annotations {
            for annotation in page.annotations where annotation.shouldDisplay && annotation.type != PDFAnnotationSubtype.popup.name {
                context.saveGState()
                annotation.draw(with: .mediaBox, in: context)
                context.restoreGState()
            }
        }
        after(context)
        return context.makeImage()
    }

    /// The page as the reader sees it (crop box, rotation applied, annotations drawn)
    /// at `scale` pixels per point. Used for "Export as PNG/JPEG".
    static func displayImage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let crop = page.bounds(for: .cropBox)
        let size = Geometry.displaySize(crop: crop, rotation: page.rotation)
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let image = page.thumbnail(of: pixels, for: .cropBox)
        var rect = CGRect(origin: .zero, size: pixels)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Encodes a bitmap. `quality` applies to JPEG only (0…1).
    static func encode(_ image: CGImage, as type: UTType, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Redaction that removes content instead of hiding it.
///
/// Drawing a black box over text leaves the text in the file: anyone can select,
/// copy or extract it. Folio instead rasterises the whole page with the boxes painted
/// in, and replaces the page with that image. The result carries no text, vector
/// paths, images or annotations from the original page, only pixels.
///
/// The trade-off: the page loses selectable text everywhere, not just under the box.
/// Run *Recognize Text* afterwards to make the rest of the page searchable again.
nonisolated enum Redactor {
    /// About 216 dpi: sharp enough to read and print, small enough to stay light.
    static let scale: CGFloat = 3

    /// An image-only copy of `page` with `rects` (page space) painted solid black.
    static func redact(_ page: PDFPage, rects: [CGRect]) -> PDFPage? {
        let media = page.bounds(for: .mediaBox)
        guard
            let image = Rasterizer.raster(
                page, scale: scale,
                after: { context in
                    context.setFillColor(.black)
                    context.fill(rects)
                })
        else { return nil }
        guard
            let redacted = PageFactory.render(
                mediaBox: media,
                draw: { context in
                    context.interpolationQuality = .high
                    context.draw(image, in: media)
                })
        else { return nil }
        PageRebuilder.copyGeometry(from: page, to: redacted)
        return redacted
    }
}
