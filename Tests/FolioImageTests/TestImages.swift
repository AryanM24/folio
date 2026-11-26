import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import FolioImage

/// Synthetic images for tests: a left-to-right red→blue gradient with a white square
/// in the top-left quarter, so orientation and crops are easy to check by sampling.
enum TestImages {
    static func cgImage(width: Int = 400, height: Int = 300, alpha: Bool = false) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                                                               CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        // CG is y-up: the top-left quarter is at high y.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    static let gps: [String: Any] = [
        kCGImagePropertyGPSLatitude as String: 48.8584, kCGImagePropertyGPSLatitudeRef as String: "N",
        kCGImagePropertyGPSLongitude as String: 2.2945, kCGImagePropertyGPSLongitudeRef as String: "E",
    ]

    static let exif: [String: Any] = [
        kCGImagePropertyExifDateTimeOriginal as String: "2024:06:01 10:00:00",
        kCGImagePropertyExifFNumber as String: 1.8,
    ]

    /// Encoded test image with optional camera metadata and EXIF orientation.
    static func data(_ type: UTType = .jpeg, width: Int = 400, height: Int = 300, metadata: Bool = false, orientation: UInt32 = 1) -> Data {
        var props: [String: Any] = [kCGImagePropertyOrientation as String: orientation]
        if metadata {
            props[kCGImagePropertyGPSDictionary as String] = gps
            props[kCGImagePropertyExifDictionary as String] = exif
            props[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFMake as String: "Folio", kCGImagePropertyTIFFModel as String: "Test"]
        }
        return try! ImageCodec.encode(cgImage(width: width, height: height), as: type, properties: props)
    }

    static func properties(of data: Data) -> [String: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }

    static func size(of data: Data) -> CGSize {
        let p = properties(of: data)
        return CGSize(width: p[kCGImagePropertyPixelWidth as String] as? Int ?? 0, height: p[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
    }

    /// RGBA at a pixel (top-left origin), 0…255.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so that pixel (x, y) from the top lands on our single pixel.
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }

    static func decode(_ data: Data) -> CGImage {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    /// Average color of an image.
    static func mean(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let w = 16, h = 16
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            r += Double(bytes[i]); g += Double(bytes[i + 1]); b += Double(bytes[i + 2])
        }
        let n = Double(w * h)
        return (r / n, g / n, b / n)
    }
}
