import AppKit
import PDFKit

/// A Stamp annotation that shows a bitmap: images, signatures and Folio's stamps.
///
/// PDFKit calls `draw(with:in:)` both on screen and when it writes the file, where
/// the drawing becomes the annotation's appearance stream. So the picture is stored in
/// the PDF itself and shows in every reader, while staying a movable, resizable
/// annotation. After reopening, PDFKit loads it as a plain Stamp that draws its saved
/// appearance, which is why nothing else in Folio depends on this class.
///
/// `nonisolated` because PDFKit draws annotations on its rendering threads.
nonisolated final class ImageAnnotation: PDFAnnotation, @unchecked Sendable {
    // @unchecked: `image` is immutable and CGImage is thread-safe; PDFAnnotation's own
    // state is guarded the same way PDFKit guards it for every annotation.
    let image: CGImage

    init(image: CGImage, bounds: CGRect, name: String) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        contents = name
        color = .black
        userName = AnnotationFactory.authorName
        modificationDate = Date()
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setAlpha(color.alphaComponent)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    /// A size for `image` no larger than `maxSide` points, keeping its aspect ratio.
    /// Images are placed at 2 pixels per point so they look crisp on Retina screens.
    static func size(for image: CGImage, maxSide: CGFloat) -> CGSize {
        let natural = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        let scale = min(1, maxSide / max(natural.width, natural.height, 1))
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }
}

extension PDFAnnotation {
    /// A copy that survives saving, for moving annotations onto rebuilt pages.
    ///
    /// `PDFAnnotation.copy()` looks right on screen but its copies are silently dropped
    /// when the document is written (verified in tests), so copies are rebuilt from the
    /// annotation's PDF dictionary instead. Folio's own image stamps carry their bitmap
    /// outside that dictionary until first save, so they are recreated directly.
    nonisolated func persistentCopy() -> PDFAnnotation {
        if let image = self as? ImageAnnotation {
            let copy = ImageAnnotation(image: image.image, bounds: bounds, name: contents ?? "Image")
            copy.color = color
            return copy
        }
        return PDFAnnotation(
            bounds: bounds, forType: PDFAnnotationSubtype(rawValue: "/" + (type ?? "Square")), withProperties: annotationKeyValues)
    }
}
