import FolioKit
import PDFKit
import Quartz

/// "Reduce File Size", the same way Preview does it: every page is redrawn through
/// macOS's *Reduce File Size* Quartz filter, which downsamples and JPEG-compresses
/// images while text and vector art stay vector.
///
/// (PDFKit's `saveImagesAsJPEG` / `optimizeImagesForScreen` write options looked like
/// the native route but leave existing image streams untouched; measured in tests.)
nonisolated enum Compressor {
    static let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")

    /// A smaller copy of `document`. Annotations, page boxes, rotation, document
    /// properties and the outline (page-level targets) are carried over; only page
    /// content is re-encoded.
    static func compressed(_ document: PDFDocument) throws -> Data {
        guard let filter = QuartzFilter(url: filterURL) else {
            throw FolioError("macOS's Reduce File Size filter isn't available on this Mac.")
        }
        let data = NSMutableData()
        var box = document.page(at: 0)?.bounds(for: .mediaBox) ?? PageFactory.letter
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw FolioError("Folio couldn't create the smaller PDF.") }
        filter.apply(to: context)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let ref = page.pageRef else { continue }
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(rect: page.bounds(for: .mediaBox))] as CFDictionary)
            context.drawPDFPage(ref)
            context.endPDFPage()
        }
        filter.remove(from: context)
        if let outline = outlineDictionary(for: document) { CGPDFContextSetOutline(context, outline as CFDictionary) }
        context.closePDF()

        guard let result = PDFDocument(data: data as Data), result.pageCount == document.pageCount else {
            throw FolioError("Folio couldn't create the smaller PDF.")
        }
        for index in 0..<document.pageCount {
            guard let source = document.page(at: index), let target = result.page(at: index) else { continue }
            PageRebuilder.copyGeometry(from: source, to: target)
            for annotation in source.annotations where annotation.type != PDFAnnotationSubtype.popup.name {
                target.addAnnotation(annotation.persistentCopy())
            }
        }
        result.documentAttributes = document.documentAttributes
        return try PDFOperations.data(result)
    }

    /// The outline in the form `CGPDFContextSetOutline` takes: titles, 1-based page
    /// numbers and children. (PDFKit doesn't save `PDFOutline` trees built in code,
    /// but Quartz writes this one natively.)
    static func outlineDictionary(for document: PDFDocument) -> [String: Any]? {
        func entries(_ outline: PDFOutline) -> [[String: Any]] {
            (0..<outline.numberOfChildren).compactMap { index in
                guard let child = outline.child(at: index) else { return nil }
                var entry: [String: Any] = ["Title": child.label ?? ""]
                if let page = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page {
                    let pageIndex = document.index(for: page)
                    if pageIndex != NSNotFound { entry["Destination"] = pageIndex + 1 }
                }
                let children = entries(child)
                if !children.isEmpty { entry["Children"] = children }
                return entry
            }
        }
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else { return nil }
        return ["Children": entries(root)]
    }
}
