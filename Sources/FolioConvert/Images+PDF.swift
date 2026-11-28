import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ImageConverter {
    /// Image → one-page PDF. JPEG bytes are embedded as they are (Quartz passes DCT data
    /// through when the image comes from a JPEG data provider) and PNG pixels go in as
    /// Flate, so both are lossless. Other sources, and `small`, are stored as JPEG.
    static func writePDF(_ source: CGImageSource, props: [CFString: Any], job: Job, maxPixels: Int?) throws -> Outcome {
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let asIs = (job.source == .jpeg || job.source == .png) && job.quality != .small && maxPixels == nil
        // Rotations are applied to the page content so the JPEG stays untouched; mirrors need a decode.
        let turned = asIs && [1, 3, 6, 8].contains(orientation)
        let image: CGImage
        if turned {
            if job.source == .jpeg, let provider = CGDataProvider(url: job.input as CFURL),
                let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            {
                image = jpeg
            } else {
                guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw undecodable(job) }
                image = decoded
            }
        } else {
            guard let upright = uprightImage(source, props: props, maxPixels: maxPixels) else { throw undecodable(job) }
            if !asIs && !hasAlpha {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw undecodable(job)
                }
                CGImageDestinationAddImage(
                    destination, upright, [kCGImageDestinationLossyCompressionQuality: job.quality == .small ? 0.6 : 0.85] as CFDictionary)
                guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data),
                    let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw undecodable(job) }
                image = jpeg
            } else {
                image = upright
            }
        }
        let drawn = turned ? orientation : 1
        let (pixelsWide, pixelsHigh) = [6, 8].contains(drawn) ? (image.height, image.width) : (image.width, image.height)
        let scale = 72 / dpi
        var box = CGRect(x: 0, y: 0, width: Double(pixelsWide) * scale, height: Double(pixelsHigh) * scale)
        guard let context = CGContext(job.output as CFURL, mediaBox: &box, nil) else {
            throw ConvertError(.internal, "Couldn't create the PDF.")
        }
        context.beginPDFPage(nil)
        switch drawn {
        case 3:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 6:
            context.translateBy(x: 0, y: box.height)
            context.rotate(by: -.pi / 2)
        case 8:
            context.translateBy(x: box.width, y: 0)
            context.rotate(by: .pi / 2)
        default: break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale))
        context.endPDFPage()
        context.closePDF()

        var outcome = Outcome(
            fidelity: asIs ? .lossless : .lossy, method: asIs ? "embed" : "encode",
            details: [
                "width": .int(Int64(pixelsWide)), "height": .int(Int64(pixelsHigh)),
                "page_size": .array([.double(box.width), .double(box.height)]),
            ])
        if job.verify {
            outcome.verification = verifyPDF(
                job: job, source: source, props: props, width: pixelsWide, height: pixelsHigh, dpi: dpi, lossless: asIs)
        }
        return outcome
    }

    /// The image with its orientation applied, optionally downscaled.
    static func uprightImage(_ source: CGImageSource, props: [CFString: Any], maxPixels: Int?) -> CGImage? {
        let edge = maxPixels ?? max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge, kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Renders the page back at the image's own resolution and compares it with the upright source, both over white.
    static func verifyPDF(
        job: Job, source: CGImageSource, props: [CFString: Any], width: Int, height: Int, dpi: Double, lossless: Bool
    ) -> Verification {
        guard let page = CGPDFDocument(job.output as CFURL)?.page(at: 1),
            let original = uprightImage(source, props: props, maxPixels: max(width, height))
        else { return Verification(passed: false, checks: ["opens"]) }
        let diff = PixelDiff(
            width: width, height: height, wide: false, white: true,
            { context in
                context.scaleBy(x: dpi / 72, y: dpi / 72)
                context.drawPDFPage(page)
            },
            { context in context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height)) })
        return Verification(
            passed: !lossless || diff.identical, checks: ["opens", lossless ? "pixels identical" : "psnr"], metrics: diff.metrics)
    }

    static func undecodable(_ job: Job) -> ConvertError {
        ConvertError(.corruptInput, "Couldn't decode \(job.input.lastPathComponent).")
    }
}
