import CoreImage
public import FolioKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File tools owned by this module. Surfaced in the workspace's Tools view, File > Tools and
/// Finder Quick Actions. See `FolioTool`. Each runs ``ImageToolOps`` per file.
public enum ImageTools {
    public nonisolated static let all: [FolioTool] = [convert, resize, removeBackground, stripMetadata]

    private nonisolated static let inputs = FileKind.image.readableTypes

    private nonisolated static let qualityOption = FolioTool.Option(
        id: "quality", label: "Quality",
        choices: [("0.92", "High"), ("0.8", "Medium"), ("0.6", "Small file")], defaultValue: "0.92"
    )

    nonisolated static let convert = FolioTool(
        id: "image.convert", title: "Convert Images", subtitle: "Save copies as PNG, JPEG, HEIC or TIFF",
        symbol: "photo.on.rectangle.angled", inputTypes: inputs,
        options: [
            .init(
                id: "format", label: "Format", choices: [("png", "PNG"), ("jpeg", "JPEG"), ("heic", "HEIC"), ("tiff", "TIFF")],
                defaultValue: "jpeg"),
            qualityOption,
        ]
    ) { urls, options in
        let type = ImageToolOps.type(named: options["format"] ?? "jpeg")
        let quality = Double(options["quality"] ?? "") ?? 0.92
        return try each(urls) { url, data in
            (try ImageToolOps.convert(data, to: type, quality: quality), url.deletingPathExtension().lastPathComponent, type)
        }
    }

    nonisolated static let resize = FolioTool(
        id: "image.resize", title: "Resize Images", subtitle: "Shrink and compress copies for sharing",
        symbol: "arrow.down.right.and.arrow.up.left", inputTypes: inputs,
        options: [
            .init(
                id: "maxSize", label: "Longest side",
                choices: [("1024", "1024 px"), ("2048", "2048 px"), ("3000", "3000 px"), ("4096", "4096 px")], defaultValue: "2048"),
            qualityOption,
        ]
    ) { urls, options in
        let maxEdge = Int(options["maxSize"] ?? "") ?? 2048
        let quality = Double(options["quality"] ?? "") ?? 0.92
        return try each(urls) { url, data in
            let (out, type) = try ImageToolOps.resize(data, maxEdge: maxEdge, quality: quality)
            return (out, "\(url.deletingPathExtension().lastPathComponent) (\(maxEdge) px)", type)
        }
    }

    nonisolated static let removeBackground = FolioTool(
        id: "image.removeBackground", title: "Remove Background", subtitle: "Cut out the subject as a transparent PNG",
        symbol: "person.and.background.dotted", inputTypes: inputs
    ) { urls, _ in
        try each(urls) { url, data in
            (try ImageToolOps.removeBackground(data), "\(url.deletingPathExtension().lastPathComponent) (no background)", .png)
        }
    }

    nonisolated static let stripMetadata = FolioTool(
        id: "image.stripMetadata", title: "Remove Location & Metadata", subtitle: "Copies without GPS, camera and date details",
        symbol: "location.slash", inputTypes: inputs
    ) { urls, _ in
        try each(urls) { url, data in
            let out = try ImageCodec.strippingMetadata(data)
            let type = ImageCodec.detectedType(of: out, hint: nil) ?? .png
            return (out, "\(url.deletingPathExtension().lastPathComponent) (no metadata)", type)
        }
    }

    /// Run `work` on each input and write results next to it, never overwriting.
    private nonisolated static func each(_ urls: [URL], _ work: (URL, Data) throws -> (Data, String, UTType)) throws -> [URL] {
        try urls.map { url in
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                throw FolioError("Couldn't read “\(url.lastPathComponent)”.")
            }
            let (out, name, type) = try work(url, data)
            let target = FolioTool.outputURL(nextTo: url, name: name, ext: type.preferredFilenameExtension ?? "png")
            try out.write(to: target, options: .atomic)
            return target
        }
    }
}

/// The pure operations behind ``ImageTools``: bytes in, bytes out.
nonisolated enum ImageToolOps {
    static func type(named name: String) -> UTType {
        switch name {
        case "png": .png
        case "heic": .heic
        case "tiff": .tiff
        default: .jpeg
        }
    }

    /// Re-encode `data` as `type`, keeping metadata and applying EXIF orientation.
    static func convert(_ data: Data, to type: UTType, quality: Double) throws -> Data {
        let source = try SourceImage(data: data)
        let image = try RenderPipeline.render(source, recipe: EditRecipe(), final: true, flattenFor: type)
        return try ImageCodec.encode(
            image, as: type, quality: quality, properties: ImageCodec.propertiesForSaving(source.properties, strip: false))
    }

    /// Shrink so the long side is at most `maxEdge` (never enlarges). Keeps the format
    /// when macOS can write it, otherwise JPEG.
    static func resize(_ data: Data, maxEdge: Int, quality: Double) throws -> (Data, UTType) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let width = props[kCGImagePropertyPixelWidth as String] as? Int,
            let height = props[kCGImagePropertyPixelHeight as String] as? Int
        else { throw FolioError("This file isn't an image Folio can read.") }
        let detected = CGImageSourceGetType(source).flatMap { UTType($0 as String) } ?? .jpeg
        let type = ImageCodec.canWrite(detected) ? detected : .jpeg
        // ImageIO's thumbnail path decodes at reduced size directly: fast and sharp.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxEdge, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FolioError("Couldn't resize this image.")
        }
        let out = try ImageCodec.encode(image, as: type, quality: quality, properties: ImageCodec.propertiesForSaving(props, strip: false))
        return (out, type)
    }

    /// The subject on a transparent background, as PNG.
    static func removeBackground(_ data: Data) throws -> Data {
        let source = try SourceImage(data: data)
        var recipe = EditRecipe()
        recipe.removeBackground = true
        let image = try RenderPipeline.render(source, recipe: recipe, final: true)
        return try ImageCodec.encode(image, as: .png, properties: ImageCodec.propertiesForSaving(source.properties, strip: false))
    }
}
