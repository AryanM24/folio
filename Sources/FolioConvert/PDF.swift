import AppKit
public import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// PDF conversions, built on PDFKit and Quartz filters.
///
/// PDFKit objects aren't thread-safe, so every parallel task opens its own document.
public nonisolated enum PDFConverter: FamilyConverter {
    public static let family: Format.Family = .pdf

    public static func targets(from source: Format) -> [Target] {
        guard source == .pdf else { return [] }
        let raster = ["text layer", "links", "vector art"]
        let text = ["page layout", "images"]
        return [
            Target(
                to: .pdf, fidelity: .lossy, losslessAvailable: true,
                notes: "Compress: images are recompressed as JPEG, text and vectors stay sharp. Lossless only rewrites the file."),
            Target(to: .png, fidelity: .lossless, losslessAvailable: true, drops: raster, notes: "One image per page."),
            Target(to: .jpeg, fidelity: .lossy, losslessAvailable: false, drops: raster, notes: "One image per page."),
            Target(to: .heic, fidelity: .lossy, losslessAvailable: false, drops: raster, notes: "One image per page."),
            Target(to: .tiff, fidelity: .lossless, losslessAvailable: true, drops: raster, notes: "One image per page."),
            Target(to: .txt, fidelity: .contentOnly, losslessAvailable: false, drops: text + ["formatting"]),
            Target(to: .md, fidelity: .contentOnly, losslessAvailable: false, drops: text + ["formatting"]),
            Target(to: .docx, fidelity: .contentOnly, losslessAvailable: false, drops: text),
            Target(to: .rtf, fidelity: .contentOnly, losslessAvailable: false, drops: text),
        ]
    }

    public static func convert(_ job: Job) async throws -> Outcome {
        let document = try open(job.input)
        if job.target == .pdf, document.isEncrypted {
            throw ConvertError(.encrypted, "\(job.input.lastPathComponent) is password-protected; rewriting it would drop the protection.")
        }
        switch job.target {
        case .pdf: return try job.quality == .lossless ? rewrite(document, job: job) : compress(document, job: job)
        case .png, .jpeg, .heic, .tiff: return try await rasterize(job: job, pages: document.pageCount)
        case .txt, .md:
            let text = try await extract(document, url: job.input, as: job.target == .md ? .markdown : .text, pages: nil)
            try Data(text.utf8).write(to: job.output)
            return Outcome(
                fidelity: .contentOnly, method: "extract", details: ["characters": .int(Int64(text.count))],
                dropped: ["page layout", "images"])
        case .docx, .rtf: return try richText(document, job: job)
        default: throw ConvertError(.unsupportedPair, "Folio can't turn a PDF into \(job.target.title).")
        }
    }

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw ConvertError(.corruptInput, "\(url.lastPathComponent) isn't a PDF Folio can read.")
        }
        if document.isLocked {
            throw ConvertError(
                .encrypted, "\(url.lastPathComponent) is locked with a password.", hint: "Unlock it in Folio or Preview first.")
        }
        return document
    }

    // MARK: PDF → PDF

    /// Lossless: PDFKit rewrites the file without touching any stream.
    static func rewrite(_ document: PDFDocument, job: Job) throws -> Outcome {
        guard let data = document.dataRepresentation() else { throw ConvertError(.internal, "Folio couldn't write the PDF.") }
        try data.write(to: job.output)
        var outcome = Outcome(fidelity: .lossless, method: "rewrite", details: ["pages": .int(Int64(document.pageCount))])
        if job.verify { outcome.verification = verifyPDF(job: job, comparePixels: true) }
        return outcome
    }

    /// Quartz filter settings per preset (research §2.3), tightened by `maxDimension`.
    static func filterSettings(_ job: Job) -> (quality: Double, maxPixels: Int, dpi: Int) {
        let base = job.quality == .small ? (0.4, 1200, 96) : (0.6, 2048, 150)
        return (base.0, min(base.1, job.maxDimension ?? .max), base.2)
    }

    /// Redraws every page through a custom *Reduce File Size*-style filter, then re-attaches
    /// annotations, page geometry, document attributes and the outline, as `Compressor` does.
    static func compress(_ document: PDFDocument, job: Job) throws -> Outcome {
        var settings = filterSettings(job)
        var data = try filtered(document, settings)
        if let budget = job.maxBytes, data.count > budget, job.quality == .balanced {
            settings = (0.4, min(1200, settings.maxPixels), 96)
            data = try filtered(document, settings)
        }
        try data.write(to: job.output)
        var outcome = Outcome(
            fidelity: .lossy, method: "encode",
            details: [
                "pages": .int(Int64(document.pageCount)), "quality": .double(settings.quality),
                "max_image_pixels": .int(Int64(settings.maxPixels)), "dpi": .int(Int64(settings.dpi)),
            ], dropped: ["image quality"])
        if job.verify { outcome.verification = verifyPDF(job: job, comparePixels: false) }
        return outcome
    }

    static func filtered(_ document: PDFDocument, _ settings: (quality: Double, maxPixels: Int, dpi: Int)) throws -> Data {
        let plist: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true], "FilterType": 1, "Name": "Folio \(settings.quality)",
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": settings.quality, "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": settings.dpi, "ImageScaleInterpolate": true, "ImageSizeMax": settings.maxPixels,
                            "ImageSizeMin": 0,
                        ],
                    ]
                ]
            ],
        ]
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-\(UUID().uuidString).qfilter")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let filter = QuartzFilter(url: url) else { throw ConvertError(.internal, "Quartz couldn't load the compression filter.") }

        let data = NSMutableData()
        var box = document.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw ConvertError(.internal, "Folio couldn't create the smaller PDF.") }
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
            throw ConvertError(.internal, "Folio couldn't create the smaller PDF.")
        }
        for index in 0..<document.pageCount {
            guard let source = document.page(at: index), let target = result.page(at: index) else { continue }
            let crop = source.bounds(for: .cropBox)
            if crop != source.bounds(for: .mediaBox) { target.setBounds(crop, for: .cropBox) }
            target.rotation = source.rotation
            // `type` has no leading slash; popups come back with their parent.
            for annotation in source.annotations where annotation.type != "Popup" {
                target.addAnnotation(
                    PDFAnnotation(
                        bounds: annotation.bounds, forType: PDFAnnotationSubtype(rawValue: "/" + (annotation.type ?? "Square")),
                        withProperties: annotation.annotationKeyValues))
            }
        }
        result.documentAttributes = document.documentAttributes
        guard let output = result.dataRepresentation() else { throw ConvertError(.internal, "Folio couldn't write the PDF.") }
        return output
    }

    /// The outline in the form `CGPDFContextSetOutline` takes (PDFKit doesn't save
    /// `PDFOutline` trees built in code, but Quartz writes this one natively).
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

    /// Same page count and the same text on every page; for a lossless rewrite also page 1's pixels at 72 dpi.
    static func verifyPDF(job: Job, comparePixels: Bool) -> Verification {
        guard let before = PDFDocument(url: job.input), let after = PDFDocument(url: job.output) else {
            return Verification(passed: false, checks: ["opens"])
        }
        var checks = ["opens", "page count", "text identical"]
        var passed = before.pageCount == after.pageCount
        if passed {
            passed = (0..<before.pageCount).allSatisfy { before.page(at: $0)?.string ?? "" == after.page(at: $0)?.string ?? "" }
        }
        var metrics: [String: Double] = ["pages": Double(after.pageCount)]
        if comparePixels, passed, let a = before.page(at: 0), let b = after.page(at: 0) {
            let size = displaySize(a)
            let diff = PixelDiff(
                width: Int(size.width.rounded()), height: Int(size.height.rounded()), wide: false, white: true, { draw(a, in: $0) },
                { draw(b, in: $0) })
            checks.append("page 1 pixels identical")
            passed = diff.identical
            metrics.merge(diff.metrics) { $1 }
        }
        return Verification(passed: passed, checks: checks, metrics: metrics)
    }

    // MARK: PDF → images

    /// Pixels per point and encoder quality per preset and target.
    static func rasterSettings(_ job: Job) -> (dpi: Double, quality: Double?) {
        let dpi: Double = job.quality == .lossless ? 300 : job.quality == .small ? 96 : 150
        let quality: Double? =
            switch job.target {
            case .jpeg: job.quality == .small ? 0.7 : 0.85
            case .heic: job.quality == .small ? 0.6 : 0.8
            default: nil
            }
        return (dpi, quality)
    }

    /// One file for one page, else a folder of `page-001.png`…, rendered on every core with
    /// one `PDFDocument` per worker.
    static func rasterize(job: Job, pages: Int) async throws -> Outcome {
        guard pages > 0 else { throw ConvertError(.corruptInput, "\(job.input.lastPathComponent) has no pages.") }
        let settings = rasterSettings(job)
        let folder = pages > 1
        if folder { try FileManager.default.createDirectory(at: job.output, withIntermediateDirectories: false) }
        let workers = min(ProcessInfo.processInfo.activeProcessorCount, pages)
        let first = try await withThrowingTaskGroup(of: CGSize?.self) { group in
            for worker in 0..<workers {
                group.addTask {
                    guard let document = PDFDocument(url: job.input) else { throw ConvertError(.corruptInput, "Couldn't reopen the PDF.") }
                    var firstSize: CGSize?
                    for index in stride(from: worker, to: pages, by: workers) {
                        try Task.checkCancellation()
                        guard let page = document.page(at: index) else { continue }
                        let url =
                            folder
                            ? job.output.appending(path: String(format: "page-%03d.%@", index + 1, job.target.fileExtension)) : job.output
                        let size = try autoreleasepool { try renderPage(page, to: url, job: job, settings: settings) }
                        if index == 0 { firstSize = size }
                    }
                    return firstSize
                }
            }
            var size: CGSize?
            var done = 0
            for try await result in group {
                if let result { size = result }
                done += 1
                job.progress(Double(done) / Double(workers))
            }
            return size ?? .zero
        }
        var details: [String: JSONValue] = [
            "pages": .int(Int64(pages)), "dpi": .int(Int64(settings.dpi)), "width": .int(Int64(first.width)),
            "height": .int(Int64(first.height)),
        ]
        if let q = settings.quality { details["quality"] = .double(q) }
        var outcome = Outcome(
            fidelity: [.png, .tiff].contains(job.target) ? .lossless : .lossy, method: "render", details: details,
            dropped: ["text layer", "links", "vector art"], isDirectory: folder)
        if job.verify {
            let written = folder ? (try? FileManager.default.contentsOfDirectory(atPath: job.output.path).count) ?? 0 : 1
            outcome.verification = Verification(
                passed: written == pages, checks: ["opens", "one image per page"], metrics: ["pages": Double(written)])
        }
        return outcome
    }

    /// The page as a reader sees it: crop box, rotation and annotations, over white.
    static func renderImage(_ page: PDFPage, dpi: Double, maxDimension: Int?) -> CGImage? {
        let size = displaySize(page)
        var scale = dpi / 72
        if let maxDimension, max(size.width, size.height) * scale > Double(maxDimension) {
            scale = Double(maxDimension) / max(size.width, size.height)
        }
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        draw(page, in: context)
        return context.makeImage()
    }

    static func displaySize(_ page: PDFPage) -> CGSize {
        let crop = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    static func draw(_ page: PDFPage, in context: CGContext) {
        page.draw(with: .cropBox, to: context)  // applies the crop origin and rotation itself
    }

    static func renderPage(_ page: PDFPage, to url: URL, job: Job, settings: (dpi: Double, quality: Double?)) throws -> CGSize {
        guard let image = renderImage(page, dpi: settings.dpi, maxDimension: job.maxDimension),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, job.target.contentType.identifier as CFString, 1, nil)
        else { throw ConvertError(.internal, "Couldn't render a page of \(job.input.lastPathComponent).") }
        var options: [CFString: Any] = [kCGImagePropertyDPIWidth: settings.dpi, kCGImagePropertyDPIHeight: settings.dpi]
        if let q = settings.quality { options[kCGImageDestinationLossyCompressionQuality] = q }
        if job.target == .png { options[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGCompressionFilter: 0x10] }
        if job.target == .tiff { options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConvertError(.internal, "Couldn't encode a page as \(job.target.title).")
        }
        return CGSize(width: image.width, height: image.height)
    }

    // MARK: PDF → text

    /// Text per page via the attributed text layer; layout and images are gone.
    static func richText(_ document: PDFDocument, job: Job) throws -> Outcome {
        let text = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.attributedString else { continue }
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(page)
        }
        let type: NSAttributedString.DocumentType = job.target == .docx ? .officeOpenXML : .rtf
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
        try data.write(to: job.output)
        return Outcome(
            fidelity: .contentOnly, method: "extract",
            details: ["pages": .int(Int64(document.pageCount)), "characters": .int(Int64(text.length))],
            dropped: ["page layout", "images"],
            warnings: text.length == 0 ? ["This PDF has no text layer; run folio extract to OCR it."] : [])
    }

    public static func inspect(_ url: URL, format: Format) async throws -> [String: JSONValue] {
        guard let document = PDFDocument(url: url) else {
            throw ConvertError(.corruptInput, "\(url.lastPathComponent) isn't a PDF Folio can read.")
        }
        var meta: [String: JSONValue] = [
            "pages": .int(Int64(document.pageCount)), "encrypted": .bool(document.isEncrypted), "locked": .bool(document.isLocked),
        ]
        guard !document.isLocked else { return meta }
        meta["has_text_layer"] = .bool(
            (0..<min(document.pageCount, 10)).contains {
                !(document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        if let size = document.page(at: 0).map(displaySize) { meta["page_size"] = .array([.double(size.width), .double(size.height)]) }
        let attributes = document.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { meta["title"] = .string(title) }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty { meta["author"] = .string(author) }
        return meta
    }

    public static func extract(_ url: URL, format: Format, as kind: ExtractKind, options: ExtractOptions) async throws -> String {
        try await extract(try open(url), url: url, as: kind, pages: options.pages)
    }

    /// The text layer per page; when there's none, Vision OCR of each page at 200 dpi.
    static func extract(_ document: PDFDocument, url: URL, as kind: ExtractKind, pages: ClosedRange<Int>?) async throws -> String {
        let all = 1...max(document.pageCount, 1)
        let range = (pages ?? all).clamped(to: all)
        var texts = range.map { document.page(at: $0 - 1)?.string ?? "" }
        if texts.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            texts = try range.map { number in
                try Task.checkCancellation()
                guard let page = document.page(at: number - 1), let image = renderImage(page, dpi: 200, maxDimension: nil) else {
                    return ""
                }
                return try ImageConverter.recognizeText(in: image)
            }
        }
        return texts.joined(separator: kind == .markdown ? "\n\n---\n\n" : "\n\n")
    }
}
