import AppKit
import CoreGraphics
import CoreImage
import FolioKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// The original image as opened: its bytes, a fast screen-sized proxy, and the
/// full-resolution decode, which is made lazily and then kept in memory.
///
/// Opening a 24 MP JPEG only decodes the proxy (the ImageIO thumbnail path uses the
/// JPEG DCT scaling, so it takes tens of milliseconds); the full decode happens in the
/// background after first paint or when a save needs it.
///
/// SVG files are rasterized on open (ImageIO can not read them): `data` then holds the
/// rendered PNG and `type` stays SVG, so saving goes through Export.
///
/// `@unchecked Sendable`: every stored property is an immutable `let` (ImageIO and
/// Core Graphics objects here are immutable once made) except the caches, which are
/// guarded by `Mutex`.
nonisolated final class SourceImage: @unchecked Sendable {
    /// The file bytes, exactly as read. Saved back untouched when nothing changed.
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
    /// The file carries an HDR gain map (ISO 21496-1 or Apple), kept on save per `HDRPolicy`.
    let hasGainMap: Bool
    /// The pixels are PQ or HLG encoded (HDR10, HLG stills).
    let usesHDRTransfer: Bool
    /// Decodes apply the gain map, giving extended range (see ``hdrVariant()``).
    private let expandsHDR: Bool

    static let proxyMaxPixels = 2048
    /// The long edge SVGs are rasterized to on open.
    static let svgLongEdge = 2048

    private let full = Mutex<CGImage?>(nil)
    private let foregroundMask = Mutex<CIImage?>(nil)

    /// Open `data`. An SVG (sniffed from the bytes) is rasterized to `svgLongEdge` pixels on its long edge.
    convenience init(data: Data, typeHint: UTType? = nil, svgLongEdge: Int = SourceImage.svgLongEdge) throws {
        if Self.isSVG(data) {
            try self.init(decoding: Self.rasterizedSVG(data, longEdge: svgLongEdge), typeHint: .png, presentedAs: .svg)
        } else {
            try self.init(decoding: data, typeHint: typeHint)
        }
    }

    private init(decoding data: Data, typeHint: UTType?, presentedAs presented: UTType? = nil, expandsHDR: Bool = false) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0
        else { throw FolioError("This file isn’t an image Folio can read, or it’s damaged.") }
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
            throw FolioError("Couldn’t decode this image.")
        }

        self.data = data
        self.type = presented ?? typeID.flatMap(UTType.init) ?? typeHint ?? .png
        self.pixelSize = swaps ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        self.properties = props
        self.orientation = orientation
        self.proxy = proxy
        self.colorSpace =
            proxy.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        self.bitsPerComponent = props[kCGImagePropertyDepth as String] as? Int ?? 8
        self.hasAlpha = props[kCGImagePropertyHasAlpha as String] as? Bool ?? false
        self.frameCount = CGImageSourceGetCount(source)
        self.hasGainMap = [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap].contains {
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil
        }
        self.usesHDRTransfer = proxy.colorSpace.map(CGColorSpaceUsesITUR_2100TF) ?? false
        self.expandsHDR = expandsHDR
    }

    /// Proxy pixels per source pixel (≤ 1).
    var proxyScale: Double { Double(proxy.width) / pixelSize.width }

    /// The full-resolution original, oriented, as a Core Image image. Decodes on first
    /// use (thread-safe; concurrent callers wait for the one decode).
    func fullImage() throws -> CIImage {
        if expandsHDR {
            guard let hdr = CIImage(data: data, options: [.expandToHDR: true]) else {
                throw FolioError("Couldn’t decode the HDR image.")
            }
            return hdr.oriented(orientation)
        }
        let cg: CGImage = try full.withLock { cached in
            if let cached { return cached }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw FolioError("Couldn’t decode the full-size image.") }
            cached = image
            return image
        }
        return CIImage(cgImage: cg).oriented(orientation)
    }

    /// The proxy as a Core Image image.
    var proxyImage: CIImage {
        guard expandsHDR, let hdr = try? fullImage() else { return CIImage(cgImage: proxy) }
        return hdr.transformed(
            by: CGAffineTransform(scaleX: Double(proxy.width) / hdr.extent.width, y: Double(proxy.height) / hdr.extent.height),
            highQualityDownsample: true)
    }

    /// The same file decoded with its gain map applied (extended range), for rendering the
    /// HDR half of a gain-map save. `nil` when the file has no gain map.
    func hdrVariant() -> SourceImage? {
        guard hasGainMap else { return nil }
        return try? SourceImage(decoding: data, typeHint: type, presentedAs: type, expandsHDR: true)
    }

    /// Decode the full image now, so the first save or zoom does not wait.
    func warmUp() { _ = try? fullImage() }

    /// The subject mask (white = keep), at proxy resolution. Computed once with Vision.
    func subjectMask() throws -> CIImage {
        if let mask = foregroundMask.withLock({ $0 }) { return mask }
        let mask = try BackgroundRemoval.mask(for: proxy)
        foregroundMask.withLock { $0 = mask }
        return mask
    }

    /// The RAW development of this file at `scale` (`CIRAWFilter`), or `nil` when it is not
    /// a RAW file, so the pipeline uses the normal decode. Controls the camera does not
    /// support are skipped. The result is oriented and exactly `pixelSize × scale`.
    func developed(_ raw: RAWSettings, scale: Double) throws -> CIImage? {
        guard type.conforms(to: .rawImage), let filter = CIRAWFilter(imageData: data, identifierHint: type.identifier) else {
            return nil
        }
        if let pinned = raw.decoderVersion,
            let version = filter.supportedDecoderVersions.first(where: { $0.rawValue == pinned })
        {
            filter.decoderVersion = version
        }
        filter.exposure = Float(raw.exposure)
        if let value = raw.temperature { filter.neutralTemperature = Float(value) }
        if let value = raw.tint { filter.neutralTint = Float(value) }
        filter.boostAmount = Float(raw.boost)
        if let value = raw.shadowBoost { filter.boostShadowAmount = Float(value) }
        if let value = raw.contrast, filter.isContrastSupported { filter.contrastAmount = Float(value) }
        if let value = raw.detail, filter.isDetailSupported { filter.detailAmount = Float(value) }
        if let value = raw.sharpness, filter.isSharpnessSupported { filter.sharpnessAmount = Float(value) }
        if let value = raw.localToneMap, filter.isLocalToneMapSupported { filter.localToneMapAmount = Float(value) }
        if let value = raw.luminanceNoiseReduction, filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = Float(value)
        }
        if let value = raw.colorNoiseReduction, filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = Float(value) }
        if let value = raw.moireReduction, filter.isMoireReductionSupported { filter.moireReductionAmount = Float(value) }
        filter.extendedDynamicRangeAmount = Float(raw.extendedDynamicRange)
        if #available(macOS 26, *), let value = raw.highlightRecovery, filter.isHighlightRecoverySupported {
            filter.isHighlightRecoveryEnabled = value
        }
        if let value = raw.lensCorrection, filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = value }
        // Decoding at reduced size keeps previews fast; saves ask for scale 1.
        filter.scaleFactor = Float(min(1, max(0.01, scale)))
        guard let output = filter.outputImage, !output.extent.isEmpty, !output.extent.isInfinite else {
            throw FolioError("Couldn’t develop this RAW file.")
        }
        let target = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        let extent = output.extent
        let fit = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: target.width / extent.width, y: target.height / extent.height))
        return output.transformed(by: fit, highQualityDownsample: true)
    }

    /// The cached subject mask, if it was already computed.
    var cachedSubjectMask: CIImage? { foregroundMask.withLock { $0 } }

    // MARK: SVG

    /// True when the bytes are an SVG document (ImageIO can not decode those).
    static func isSVG(_ data: Data) -> Bool {
        String(decoding: data.prefix(4096), as: UTF8.self).range(of: "<svg", options: .caseInsensitive) != nil
    }

    /// Draw the SVG with the AppKit SVG renderer so its long edge is `longEdge` pixels, as PNG.
    static func rasterizedSVG(_ data: Data, longEdge: Int) throws -> Data {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw FolioError("This SVG couldn’t be drawn. It may use features macOS doesn’t support.")
        }
        let scale = Double(max(1, longEdge)) / max(image.size.width, image.size.height)
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw FolioError("This SVG is too large to open.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let raster = ctx.makeImage() else { throw FolioError("This SVG couldn’t be drawn.") }
        return try ImageCodec.encode(raster, as: .png)
    }
}
