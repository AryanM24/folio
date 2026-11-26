import AppKit
import Foundation
import PDFKit

@testable import FolioPDF

/// Generated test PDFs. Everything is built with Quartz at test time, so the repo
/// carries no binary fixtures and each test states exactly what its input contains.
enum Fixtures {
    /// A PDF whose page `i` (0-based) reads "Page i+1" plus `extra[i]` if given.
    static func document(pages: Int, extra: [Int: String] = [:]) -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<pages {
            let page = PageFactory.render(mediaBox: PageFactory.letter) { context in
                drawText("Page \(index + 1)", in: context, at: CGPoint(x: 72, y: 700), size: 24)
                if let text = extra[index] {
                    drawText(text, in: context, at: CGPoint(x: 72, y: 400), size: 18)
                }
            }
            if let page { document.insert(page, at: index) }
        }
        return document
    }

    /// Pages "Page 1"… with a table of contents, written by Quartz the way real files
    /// carry one (PDFKit doesn't save outlines built in code). `entries` maps titles to
    /// 0-based page indices; entries are sorted by page.
    static func outlined(_ entries: [String: Int]) -> PDFDocument? {
        let pages = (entries.values.max() ?? 0) + 1
        let data = NSMutableData()
        var box = PageFactory.letter
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return nil }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            drawText("Page \(index + 1)", in: context, at: CGPoint(x: 72, y: 700), size: 24)
            context.endPDFPage()
        }
        let children = entries.sorted { $0.value < $1.value }.map { ["Title": $0.key, "Destination": $0.value + 1] as [String: Any] }
        CGPDFContextSetOutline(context, ["Children": children] as CFDictionary)
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    /// A one-page PDF that is only a picture of `text`: no text layer, like a scan.
    static func scannedPage(text: String) -> PDFPage? {
        let width = 1224, height = 400
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(text, in: context, at: CGPoint(x: 60, y: 170), size: 72)
        guard let image = context.makeImage() else { return nil }
        return PageFactory.render(mediaBox: CGRect(x: 0, y: 0, width: 612, height: 200)) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: 612, height: 200))
        }
    }

    /// A page with one text form field named "name".
    static func form(value: String) -> PDFDocument {
        let document = self.document(pages: 1)
        let field = PDFAnnotation(bounds: CGRect(x: 72, y: 500, width: 300, height: 28), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "name"
        field.font = .systemFont(ofSize: 14)
        field.widgetStringValue = value
        document.page(at: 0)?.addAnnotation(field)
        return document
    }

    /// A solid-color bitmap.
    static func image(width: Int, height: Int, color: CGColor) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Random pixels: incompressible for Flate, like a photo, so JPEG wins.
    static func noise(width: Int, height: Int) -> CGImage? {
        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<(width * height * 4)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )?.makeImage()
        }
    }

    /// The sRGB color of the rendered page at a page-space point.
    static func color(of page: PDFPage, at point: CGPoint) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let image = Rasterizer.raster(page, scale: 1) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let color = rep.colorAt(x: Int(point.x), y: rep.pixelsHigh - 1 - Int(point.y))?.usingColorSpace(.sRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    /// Red after color management (device red lands near (1, 0.25, 0) in sRGB).
    static func isRed(_ c: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> Bool {
        c.red > 0.8 && c.green < 0.5 && c.blue < 0.4
    }

    /// Round-trips through PDF bytes, as a save and reopen would.
    static func reloaded(_ document: PDFDocument) -> PDFDocument? {
        document.dataRepresentation().flatMap(PDFDocument.init(data:))
    }

    /// A fresh temporary folder for tool output.
    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "FolioPDFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ document: PDFDocument, to folder: URL, name: String) throws -> URL {
        let url = folder.appending(path: "\(name).pdf")
        try PDFOperations.data(document).write(to: url)
        return url
    }

    private static func drawText(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black,
                ]))
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
