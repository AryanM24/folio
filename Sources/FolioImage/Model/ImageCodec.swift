public import CoreGraphics
import CoreImage
import FolioKit
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading and writing image files with ImageIO, plus the metadata rules for saving.
public nonisolated enum ImageCodec {
    /// Formats ImageIO can write on this Mac. WebP, notably, is read-only.
    static func canWrite(_ type: UTType) -> Bool {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return writable.contains(type.identifier)
    }

    /// Default quality when re-encoding into a lossy format: high enough that one
    /// generation is invisible, low enough that files don't balloon.
    static func defaultQuality(for type: UTType) -> Double {
        type.conforms(to: .heic) ? 0.85 : 0.92
    }

    static func isLossy(_ type: UTType) -> Bool {
        type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .webP) || type.identifier == "public.avif"
            || type.identifier == "public.jpeg-2000"
    }

    /// Whether the format can store transparency.
    static func supportsAlpha(_ type: UTType) -> Bool {
        !(type.conforms(to: .jpeg) || type.conforms(to: .bmp))
    }

    /// The content type ImageIO detects from the bytes, falling back to `hint`.
    static func detectedType(of data: Data, hint: UTType?) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let id = CGImageSourceGetType(source) as String?
        else { return hint }
        return UTType(id) ?? hint
    }

    /// Encode `image` as `type`.
    ///
    /// - Parameters:
    ///   - quality: 0…1 for lossy formats; ignored otherwise.
    ///   - properties: Metadata to embed (see ``propertiesForSaving(_:strip:)``).
    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil, properties: [String: Any] = [:]) throws -> Data {
        guard canWrite(type) else {
            throw FolioError(
                "macOS can't save \(type.localizedDescription ?? "this format") files. Use Export As to save a PNG, JPEG or HEIC copy.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw FolioError("Couldn't create a \(type.preferredFilenameExtension?.uppercased() ?? "image") file.")
        }
        var options = properties
        if isLossy(type) {
            options[kCGImageDestinationLossyCompressionQuality as String] = quality ?? defaultQuality(for: type)
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FolioError("Couldn't encode the image as \(type.preferredFilenameExtension?.uppercased() ?? "the chosen format").")
        }
        return data as Data
    }

    /// Metadata for a re-rendered image, derived from the original file's properties.
    ///
    /// Pixel dimensions are dropped (ImageIO writes the real ones), orientation is reset
    /// to "up" because rendering already applied it, and with `strip` every EXIF, GPS,
    /// IPTC, TIFF and maker dictionary is removed so nothing personal survives.
    static func propertiesForSaving(_ original: [String: Any], strip: Bool) -> [String: Any] {
        let personal: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
            kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary, kCGImagePropertyExifAuxDictionary,
            kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary, kCGImagePropertyMakerFujiDictionary,
            kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary, kCGImageProperty8BIMDictionary,
            kCGImagePropertyCIFFDictionary, kCGImagePropertyDNGDictionary, kCGImagePropertyPNGDictionary,
        ]
        let structural: [CFString] = [
            kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
            kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
            kCGImagePropertyFileContentsDictionary, kCGImagePropertyPrimaryImage, kCGImagePropertyImageCount,
            kCGImagePropertyImages, kCGImagePropertyThumbnailImages, kCGImagePropertyGIFDictionary,
        ]
        var result = original
        for key in structural { result.removeValue(forKey: key as String) }
        if strip {
            for key in personal { result.removeValue(forKey: key as String) }
            result.removeValue(forKey: kCGImagePropertyDPIWidth as String)
            result.removeValue(forKey: kCGImagePropertyDPIHeight as String)
        }
        result[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation.up.rawValue
        if var tiff = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = CGImagePropertyOrientation.up.rawValue
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            result[kCGImagePropertyExifDictionary as String] = exif
        }
        return result
    }

    /// Rewrite `data` with all metadata removed, without re-encoding pixels when the
    /// format allows (JPEG, PNG, TIFF, HEIC); otherwise falls back to a re-encode.
    static func strippingMetadata(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let typeID = CGImageSourceGetType(source),
            let type = UTType(typeID as String)
        else { throw FolioError("This file isn't an image Folio can read.") }
        let output = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(output, typeID, 1, nil) {
            let options: [String: Any] = [
                kCGImageDestinationMetadata as String: CGImageMetadataCreateMutable(),
                kCGImageDestinationMergeMetadata as String: false,
                kCGImageMetadataShouldExcludeGPS as String: true,
                kCGImageMetadataShouldExcludeXMP as String: true,
            ]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) {
                let stripped = output as Data
                if !hasPersonalMetadata(stripped) { return stripped }
            }
        }
        // Lossless copy wasn't possible (or left EXIF behind): decode and re-encode.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FolioError("Couldn't read the image to remove its metadata.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientation = CGImagePropertyOrientation(rawValue: props[kCGImagePropertyOrientation as String] as? UInt32 ?? 1) ?? .up
        let upright = orientation == .up ? image : (oriented(image, orientation) ?? image)
        return try encode(upright, as: canWrite(type) ? type : .png, properties: propertiesForSaving([:], strip: true))
    }

    /// True when the file still carries GPS, EXIF or IPTC.
    static func hasPersonalMetadata(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return false }
        if props[kCGImagePropertyGPSDictionary as String] != nil || props[kCGImagePropertyIPTCDictionary as String] != nil {
            return true
        }
        // ImageIO reports an EXIF dictionary with only pixel sizes and color space for
        // clean files; anything else (dates, camera, lens) counts as personal.
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let harmless: Set<String> = [
            kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String,
            kCGImagePropertyExifColorSpace as String,
        ]
        return !Set(exif.keys).subtracting(harmless).isEmpty
    }

    /// Apply an EXIF orientation by drawing, for the rare paths that need a CGImage.
    static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage? {
        let ci = CIImage(cgImage: image).oriented(orientation)
        return RenderPipeline.context.createCGImage(ci, from: ci.extent)
    }
}

// MARK: Icons

nonisolated extension ImageCodec {
    /// PNG-chunk icns types by edge. ImageIO writes icns only up to 512 px, so Folio writes the container itself.
    static let icnsTypes: [(edge: Int, type: String)] = [
        (1024, "ic10"), (512, "ic09"), (256, "ic08"), (128, "ic07"), (64, "icp6"), (32, "icp5"), (16, "icp4"),
    ]
    static let icoEdges = [256, 48, 32, 16]

    /// ICO edges for `image`, largest first: its own edge (capped at `standard[0]`) plus every standard size below it.
    static func iconEdges(for image: CGImage, standard: [Int]) -> [Int] {
        let top = min(max(image.width, image.height), standard[0])
        return [top] + standard.filter { $0 < top }
    }

    /// A Mac `.icns` with a PNG per standard size up to the image's own (16…1024), largest first.
    /// Lossless for a square image whose edge is one of the sizes.
    public static func icns(_ image: CGImage) throws -> Data {
        var body = Data()
        let longEdge = max(16, image.width, image.height)
        for (edge, type) in icnsTypes where edge <= longEdge {
            let png = try encode(iconSquare(image, edge: edge), as: .png)
            body.append(Data(type.utf8))
            body.append(bigEndian: UInt32(png.count + 8))
            body.append(png)
        }
        var file = Data("icns".utf8)
        file.append(bigEndian: UInt32(body.count + 8))
        return file + body
    }

    /// A Windows `.ico` ("favicon"): PNG entries at the image's own edge (capped at 256) and 48, 32 and 16, largest first.
    /// Lossless for a square image of at most 256 px.
    public static func ico(_ image: CGImage) throws -> Data {
        let pngs = try iconEdges(for: image, standard: icoEdges).map { (edge: $0, data: try encode(iconSquare(image, edge: $0), as: .png)) }
        var header = Data([0, 0, 1, 0])
        header.append(littleEndian: UInt16(pngs.count))
        var offset = 6 + 16 * pngs.count
        for png in pngs {
            let byte = UInt8(png.edge >= 256 ? 0 : png.edge)  // 0 means 256
            header.append(contentsOf: [byte, byte, 0, 0])
            header.append(littleEndian: UInt16(1))
            header.append(littleEndian: UInt16(32))
            header.append(littleEndian: UInt32(png.data.count))
            header.append(littleEndian: UInt32(offset))
            offset += png.data.count
        }
        return pngs.reduce(header) { $0 + $1.data }
    }

    /// `image` fitted into an `edge`-pixel transparent square; the image itself when it already is one.
    static func iconSquare(_ image: CGImage, edge: Int) throws -> CGImage {
        if image.width == edge, image.height == edge { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw FolioError("Couldn’t draw the icon.") }
        let scale = Double(edge) / Double(max(image.width, image.height))
        let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: (Double(edge) - size.width) / 2, y: (Double(edge) - size.height) / 2, width: size.width, height: size.height))
        guard let icon = context.makeImage() else { throw FolioError("Couldn’t draw the icon.") }
        return icon
    }
}

nonisolated extension Data {
    fileprivate mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    fileprivate mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
