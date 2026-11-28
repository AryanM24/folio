import CoreImage
public import FolioKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File tools owned by this module. Surfaced in the workspace's Tools view, File > Tools and
/// Finder Quick Actions. See `FolioTool`. Each runs ``ImageToolOps`` per file.
public enum ImageTools {
    public nonisolated static let all: [FolioTool] = [convert, resize, removeBackground, stripMetadata, export, applyPreset]

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
        return try await each(urls) { url, data in
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
        return try await each(urls) { url, data in
            let (out, type) = try ImageToolOps.resize(data, maxEdge: maxEdge, quality: quality)
            return (out, "\(url.deletingPathExtension().lastPathComponent) (\(maxEdge) px)", type)
        }
    }

    nonisolated static let removeBackground = FolioTool(
        id: "image.removeBackground", title: "Remove Background", subtitle: "Cut out the subject as a transparent PNG",
        symbol: "person.and.background.dotted", inputTypes: inputs
    ) { urls, _ in
        try await each(urls) { url, data in
            (try ImageToolOps.removeBackground(data), "\(url.deletingPathExtension().lastPathComponent) (no background)", .png)
        }
    }

    nonisolated static let stripMetadata = FolioTool(
        id: "image.stripMetadata", title: "Remove Location & Metadata", subtitle: "Copies without GPS, camera and date details",
        symbol: "location.slash", inputTypes: inputs
    ) { urls, _ in
        try await each(urls) { url, data in
            let out = try ImageCodec.strippingMetadata(data)
            let type = ImageCodec.detectedType(of: out, hint: nil) ?? .png
            return (out, "\(url.deletingPathExtension().lastPathComponent) (no metadata)", type)
        }
    }

    private nonisolated static let sizeOption = FolioTool.Option(
        id: "maxSize", label: "Size",
        choices: [("original", "Original"), ("1024", "1024 px"), ("2048", "2048 px"), ("4096", "4096 px")], defaultValue: "original")

    nonisolated static let export = FolioTool(
        id: "image.export", title: "Export Images", subtitle: "Copies in any format, size and quality, with or without metadata",
        symbol: "square.and.arrow.up.on.square", inputTypes: inputs,
        options: [
            .init(
                id: "format", label: "Format",
                choices: ExportFormat.available.map { ($0.rawValue, $0.title) }, defaultValue: ExportFormat.jpeg.rawValue),
            sizeOption, qualityOption,
            .init(id: "metadata", label: "Metadata", choices: [("keep", "Keep"), ("strip", "Remove")], defaultValue: "keep"),
        ]
    ) { urls, options in
        let settings = ImageToolOps.exportOptions(options)
        return try await ImageToolOps.applyPreset(nil, options: settings, to: urls)
    }

    nonisolated static let applyPreset = FolioTool(
        id: "image.applyPreset", title: "Apply Look to Images", subtitle: "Batch-apply a preset and save edited copies",
        symbol: "camera.filters", inputTypes: inputs,
        options: [
            .init(
                id: "preset", label: "Look", choices: ImagePreset.builtIn.map { ($0.id.uuidString, $0.name) },
                defaultValue: ImagePreset.builtIn.first?.id.uuidString ?? ""),
            .init(
                id: "format", label: "Format",
                choices: [("same", "Same as original")] + ExportFormat.available.filter { $0 != .psd }.map { ($0.rawValue, $0.title) },
                defaultValue: "same"),
            sizeOption, qualityOption,
        ]
    ) { urls, options in
        guard let preset = ImagePreset.builtIn.first(where: { $0.id.uuidString == options["preset"] }) ?? ImagePreset.builtIn.first
        else { throw FolioError("Choose a look to apply.") }
        let settings = ImageToolOps.exportOptions(options)
        return try await ImageToolOps.applyPreset(preset, options: settings, to: urls, keepFormat: options["format"] ?? "same" == "same")
    }

    /// Run `work` on each input and write results next to it, never overwriting.
    private nonisolated static func each(
        _ urls: [URL], _ work: @escaping @Sendable (URL, Data) throws -> (Data, String, UTType)
    ) async throws -> [URL] {
        // Decoding and encoding block, so they run off the Swift concurrency pool.
        try await offCooperativePool {
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

// MARK: - Export and batch

nonisolated extension ImageToolOps {
    /// Export settings from tool options (`format`, `maxSize`, `quality`, `metadata`).
    static func exportOptions(_ values: [String: String]) -> ExportOptions {
        ExportOptions(
            format: ExportFormat(rawValue: values["format"] ?? "") ?? .jpeg,
            quality: Double(values["quality"] ?? "") ?? 0.92,
            size: Int(values["maxSize"] ?? "").map(ExportOptions.Size.longEdge) ?? .original,
            stripMetadata: values["metadata"] == "strip")
    }

    /// `preset` (if any) applied to the image in `data`, written with `options`.
    static func export(_ data: Data, preset: ImagePreset?, options: ExportOptions) throws -> Data {
        let source = try SourceImage(data: data)
        let store = InMemoryAssetStore()
        let recipe = try preset?.applied(to: EditRecipe(), store: store) ?? EditRecipe()
        return try ImageSaver.export(source, recipe: recipe, assets: store, options: options)
    }

    /// Batch: `preset` and `options` applied to each file, written next to it, never
    /// overwriting. `keepFormat` saves each in its own format when macOS can write it.
    ///
    /// shortcut: one file at a time, to keep memory low on big photos; run a few at once if batches feel slow.
    static func applyPreset(_ preset: ImagePreset?, options: ExportOptions, to urls: [URL], keepFormat: Bool = false) async throws -> [URL]
    {
        try await offCooperativePool {
            try urls.map { url in
                let data: Data
                do { data = try Data(contentsOf: url) } catch {
                    throw FolioError("Couldn’t read “\(url.lastPathComponent)”.")
                }
                var options = options
                if keepFormat {
                    let detected = ImageCodec.detectedType(of: data, hint: nil)
                    options.format =
                        ExportFormat.allCases.first { $0 != .psd && detected == $0.type && ImageCodec.canWrite($0.type) } ?? .jpeg
                }
                let out = try export(data, preset: preset, options: options)
                let stem = url.deletingPathExtension().lastPathComponent
                let name = preset.map { "\(stem) (\($0.name))" } ?? stem
                let target = FolioTool.outputURL(
                    nextTo: url, name: name, ext: options.format.type.preferredFilenameExtension ?? "png")
                try out.write(to: target, options: .atomic)
                return target
            }
        }
    }
}
