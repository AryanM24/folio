import AVFoundation
import AppKit
import FolioConvert
import Foundation
import ImageIO
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension Agent {
    /// A small PNG of a page, frame or image, so an agent can look at a result.
    ///
    /// PDF pages and video frames are rendered directly (they take a page or time); anything
    /// else goes through Quick Look, with ImageIO as the fallback for images.
    public static func preview(
        _ path: String, page: Int = 1, time: Double? = nil, maxDimension: Int = 768, context: ToolContext
    ) async -> ToolOutput {
        let side = CGFloat(min(max(maxDimension, 16), 768))
        do {
            let url = try context.policy.check(path, .read)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ConvertError(.notFound, "No file at \(path).") }
            let type = UTType(filenameExtension: url.pathExtension)
            let rendered: (CGImage, String)
            if type?.conforms(to: .pdf) == true {
                rendered = try pdfPage(url, page: page, side: side)
            } else if let time, type?.conforms(to: .movie) == true {
                rendered = try await frame(url, at: time, side: side)
            } else if let thumbnail = await quickLook(url, side: side) {
                rendered = (thumbnail, "thumbnail")
            } else if let image = imageThumbnail(url, side: side) {
                rendered = (image, "image")
            } else {
                throw ConvertError(.unsupportedInput, "Folio can't draw a preview of \(url.lastPathComponent).")
            }
            guard let png = pngData(rendered.0) else { throw ConvertError(.internal, "Couldn't encode the preview.") }
            let structured: JSONValue = [
                "path": .string(url.path), "width": .int(Int64(rendered.0.width)), "height": .int(Int64(rendered.0.height)),
                "source": .string(rendered.1), "bytes": .int(Int64(png.count)),
            ]
            return ToolOutput(
                structured: structured, text: "\(url.lastPathComponent): \(rendered.1), \(rendered.0.width)×\(rendered.0.height) px",
                image: png, isError: false, ok: 1, failed: 0)
        } catch {
            return .failure(Engine.wrapped(error))
        }
    }

    private static func pdfPage(_ url: URL, page: Int, side: CGFloat) throws -> (CGImage, String) {
        guard let document = PDFDocument(url: url) else {
            throw ConvertError(.corruptInput, "\(url.lastPathComponent) isn't a readable PDF.")
        }
        if document.isLocked { throw ConvertError(.encrypted, "\(url.lastPathComponent) is password protected.") }
        guard (1...max(document.pageCount, 1)).contains(page), let pdfPage = document.page(at: page - 1) else {
            throw ConvertError(.unsupportedInput, "Page \(page) doesn't exist; the PDF has \(document.pageCount) pages.")
        }
        let thumbnail = pdfPage.thumbnail(of: CGSize(width: side, height: side), for: .mediaBox)
        guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConvertError(.internal, "Couldn't render page \(page).")
        }
        return (image, "page \(page) of \(document.pageCount)")
    }

    private static func frame(_ url: URL, at seconds: Double, side: CGFloat) async throws -> (CGImage, String) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        let (image, actual) = try await generator.image(at: CMTime(seconds: max(seconds, 0), preferredTimescale: 600))
        return (image, String(format: "frame at %.2f s", actual.seconds))
    }

    private static func quickLook(_ url: URL, side: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    private static func imageThumbnail(_ url: URL, side: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
