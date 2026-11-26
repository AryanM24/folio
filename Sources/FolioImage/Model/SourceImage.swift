import CoreGraphics
import CoreImage
import Foundation
import FolioKit
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// The original image as opened: its bytes, a fast screen-sized proxy, and the
/// full-resolution decode, which is made lazily and then kept in memory.
///
/// Opening a 24 MP JPEG only decodes the proxy (ImageIO's thumbnail path uses the
/// JPEG's DCT scaling, so it's tens of milliseconds); the full decode happens in the
/// background after first paint or when a save needs it.
///
/// `@unchecked Sendable`: every stored property is an immutable `let` (ImageIO and
/// Core Graphics objects here are immutable once made) except the caches, which are
/// guarded by `Mutex`.
nonisolated final class SourceImage: @unchecked Sendable {
    /// The file's bytes, exactly as read. Saved back untouched when nothing changed.
    let data: Data
    let type: UTType
    /// Oriented pixel size (EXIF orientation applied).
    let pixelSize: CGSize
    /// ImageIO properties of the first frame, for metadata on save and the Info popover.
    let properties: [String: Any]
    let orientation: CGImagePropertyOrientation
    /// Oriented, at most ``proxyMaxPixels`` on the long edge.
    let proxy: CGImage
    let colorSpace: CGColorSpace
    let bitsPerComponent: Int
    let hasAlpha: Bool
    let frameCount: Int

    static let proxyMaxPixels = 2048

    private let full = Mutex<CGImage?>(nil)
    private let foregroundMask = Mutex<CIImage?>(nil)

    init(data: Data, typeHint: UTType? = nil) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { throw FolioError("This file isn't an image Folio can read, or it's damaged.") }
        let typeID = CGImageSourceGetType(source).map { $0 as String }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        guard let width = props[kCGImagePropertyPixelWidth as String] as? Int,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int, width > 0, height > 0
        else { throw FolioError("This image has no pixels Folio can read.") }
        let orientation = CGImagePropertyOrientation(rawValue: props[kCGImagePropertyOrientation as String] as? UInt32 ?? 1) ?? .up
        let swaps = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(Self.proxyMaxPixels, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let proxy = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw FolioError("Couldn't decode this image.")
        }

        self.data = data
        self.type = typeID.flatMap(UTType.init) ?? typeHint ?? .png
        self.pixelSize = swaps ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        self.properties = props
        self.orientation = orientation
        self.proxy = proxy
        self.colorSpace = proxy.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.bitsPerComponent = props[kCGImagePropertyDepth as String] as? Int ?? 8
        self.hasAlpha = props[kCGImagePropertyHasAlpha as String] as? Bool ?? false
        self.frameCount = CGImageSourceGetCount(source)
    }

    /// Proxy pixels per source pixel (≤ 1).
    var proxyScale: Double { Double(proxy.width) / pixelSize.width }

    /// The full-resolution original, oriented, as a Core Image image. Decodes on first
    /// use (thread-safe; concurrent callers wait for the one decode).
    func fullImage() throws -> CIImage {
        let cg: CGImage = try full.withLock { cached in
            if let cached { return cached }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw FolioError("Couldn't decode the full-size image.") }
            cached = image
            return image
        }
        return CIImage(cgImage: cg).oriented(orientation)
    }

    /// The proxy as a Core Image image.
    var proxyImage: CIImage { CIImage(cgImage: proxy) }

    /// Decode the full image now, so the first save or zoom doesn't wait.
    func warmUp() { _ = try? fullImage() }

    /// The subject mask (white = keep), at proxy resolution. Computed once with Vision.
    func subjectMask() throws -> CIImage {
        if let mask = foregroundMask.withLock({ $0 }) { return mask }
        let mask = try BackgroundRemoval.mask(for: proxy)
        foregroundMask.withLock { $0 = mask }
        return mask
    }

    /// The cached subject mask, if it was already computed.
    var cachedSubjectMask: CIImage? { foregroundMask.withLock { $0 } }
}
