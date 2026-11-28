import AppKit
import CoreGraphics
import FolioImage
import Foundation
import ImageIO

/// SVG and EPS sources. AppKit draws SVG (`NSImage`, reliable since macOS 14): into a PDF context it stays
/// vector, into a bitmap it gives the pixels every raster target starts from. EPS can't be rendered (macOS 13
/// removed PostScript), so Folio reads the TIFF preview a DOS EPS file carries.
extension ImageConverter {
    /// The long edge SVGs are drawn at when no `max_dimension` is given (the image editor's too).
    static let svgDefaultEdge = 2048

    static func convertRendered(_ job: Job) throws -> Outcome {
        if job.source == .svg, job.target == .pdf { return try svgToPDF(job) }
        let raster: Data
        let format: Format
        if job.source == .svg {
            do {
                raster = try SourceImage.rasterizedSVG(Data(contentsOf: job.input), longEdge: job.maxDimension ?? svgDefaultEdge)
            } catch {
                throw ConvertError(.corruptInput, error.localizedDescription)
            }
            format = .png
        } else {
            raster = try epsPreview(job.input)
            format = .tiff
        }
        let temp = job.output.deletingLastPathComponent().appending(path: ".folio-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try raster.write(to: temp)
        let pixels = Job(
            input: temp, source: format, target: job.target, quality: job.quality, maxBytes: job.maxBytes, maxDimension: job.maxDimension,
            stripMetadata: job.stripMetadata, verify: job.verify, output: job.output, progress: job.progress)
        var outcome = try convertNow(pixels)
        outcome.fidelity = .lossy
        outcome.method = "render"
        outcome.dropped = targets(from: job.source).first { $0.to == job.target }?.drops ?? []
        return outcome
    }

    /// SVG → one vector PDF page, the SVG's own size in points (or `max_dimension` on the long edge).
    static func svgToPDF(_ job: Job) throws -> Outcome {
        guard let image = NSImage(contentsOf: job.input), image.size.width > 0, image.size.height > 0 else {
            throw ConvertError(.corruptInput, "\(job.input.lastPathComponent) couldn't be drawn. It may use SVG features macOS lacks.")
        }
        var size = image.size
        if let edge = job.maxDimension {
            let scale = Double(edge) / max(size.width, size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(job.output as CFURL, mediaBox: &box, nil) else {
            throw ConvertError(.internal, "Couldn't create the PDF.")
        }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: box)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        var outcome = Outcome(
            fidelity: .lossless, method: "render",
            details: ["pages": .int(1), "page_size": .array([.double(box.width), .double(box.height)])],
            dropped: targets(from: .svg).first { $0.to == .pdf }?.drops ?? [])
        if job.verify {
            let page = CGPDFDocument(job.output as CFURL)?.page(at: 1)
            outcome.verification = Verification(passed: page.map(isVector) ?? false, checks: ["opens", "no raster images"])
        }
        return outcome
    }

    /// True when the page draws no image XObjects (form XObjects aren't opened).
    static func isVector(_ page: CGPDFPage) -> Bool {
        var resources: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        guard let dictionary = page.dictionary, CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
            CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects
        else { return true }
        var images = 0
        CGPDFDictionaryApplyBlock(
            xobjects,
            { _, object, _ in
                var stream: CGPDFStreamRef?
                var subtype: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream, let info = CGPDFStreamGetDictionary(stream),
                    CGPDFDictionaryGetName(info, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image"
                {
                    images += 1
                }
                return true
            }, nil)
        return images == 0
    }

    /// The TIFF preview of a DOS EPS file (header C5D0D3C6, then little-endian offsets; Adobe TN 5002).
    static func epsPreview(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let noPreview = ConvertError(
            .unsupportedInput, "\(url.lastPathComponent) has no TIFF preview, and macOS can't render PostScript since macOS 13.",
            hint: "Export a PDF from the app that made it.")
        guard data.count >= 30, data.starts(with: [0xC5, 0xD0, 0xD3, 0xC6]) else { throw noPreview }
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << (8 * $1) }
        }
        let start = word(20)
        let length = word(24)
        guard length > 0, start >= 30, start + length <= data.count else { throw noPreview }
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + length))
    }

    static func inspectRendered(_ url: URL, format: Format) throws -> [String: JSONValue] {
        if format == .svg {
            guard let image = NSImage(contentsOf: url) else {
                throw ConvertError(.corruptInput, "\(url.lastPathComponent) couldn't be drawn.")
            }
            return ["width": .double(image.size.width), "height": .double(image.size.height), "vector": true]
        }
        guard let source = CGImageSourceCreateWithData(try epsPreview(url) as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw ConvertError(.corruptInput, "The preview inside \(url.lastPathComponent) is damaged.") }
        return [
            "preview_width": .int(Int64(props[kCGImagePropertyPixelWidth] as? Int ?? 0)),
            "preview_height": .int(Int64(props[kCGImagePropertyPixelHeight] as? Int ?? 0)),
        ]
    }
}
