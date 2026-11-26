import CoreGraphics
import CoreImage
import FolioKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading and writing image files with ImageIO, plus the metadata rules for saving.
nonisolated enum ImageCodec {
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
        type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .webP)
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
