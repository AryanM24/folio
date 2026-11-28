import CoreGraphics
import CoreImage
import FolioKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Produces the bytes written to disk for a save or an export.
nonisolated enum ImageSaver {
    /// The file contents for `recipe` applied to `source`, encoded as `type`.
    ///
    /// - Nothing that changes pixels or metadata (guides only, say): the original bytes,
    ///   untouched (no recompression, ever).
    /// - Only “remove metadata” changed: a lossless metadata rewrite.
    /// - An animation saved as GIF, APNG or HEICS: every frame, rendered, with its delay.
    /// - An HDR source with `HDRPolicy.keepIfPresent`: the gain map (HEIC, JPEG) or the PQ/HLG
    ///   encoding (16-bit) survives; `toneMapToSDR` writes standard range.
    /// - Otherwise: a full-resolution render, encoded with the original metadata
    ///   (minus orientation, which rendering applied) unless the user stripped it.
    static func data(
        for source: SourceImage, recipe: EditRecipe, assets: any AssetStore = InMemoryAssetStore(), as type: UTType,
        quality: Double? = nil
    ) throws -> Data {
        let sameFormat = type == source.type && quality == nil
        if sameFormat, !recipe.changesPixels, !recipe.stripMetadata { return source.data }
        if sameFormat, !recipe.changesPixels, source.frameCount == 1 {
            return try ImageCodec.strippingMetadata(source.data)
        }
        if source.frameCount > 1, AnimatedImage.canAnimate(type) {
            return try animated(source, recipe: recipe, assets: assets, as: type)
        }
        let properties = ImageCodec.propertiesForSaving(source.properties, strip: recipe.stripMetadata)
        if recipe.hdr == .keepIfPresent,
            let data = try gainMapped(source, recipe: recipe, assets: assets, as: type, quality: quality, properties: properties)
        {
            return data
        }
        let graph = try RenderPipeline.composite(source, recipe: recipe, assets: assets, final: true, flattenFor: type)
        var image = graph.image
        var format: CIFormat = source.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        var space = source.colorSpace
        if source.usesHDRTransfer {
            if recipe.hdr == .keepIfPresent {
                // PQ and HLG put highlights in the top of the code range; 8 bits would band.
                format = .RGBA16
            } else {
                image = image.applyingFilter("CIToneMapHeadroom", parameters: ["inputTargetHeadroom": 1.0])
                format = .RGBA8
                space = CGColorSpace(name: CGColorSpace.displayP3) ?? space
            }
        }
        let rendered = try RenderPipeline.rasterize(image, extent: graph.extent, format: format, colorSpace: space)
        return try ImageCodec.encode(rendered, as: type, quality: quality, properties: properties)
    }

    /// Every frame of an animated source with the recipe applied, keeping delays and loop count.
    private static func animated(_ source: SourceImage, recipe: EditRecipe, assets: any AssetStore, as type: UTType) throws -> Data {
        var animation = try AnimatedImage(data: source.data)
        for index in animation.frames.indices {
            // shortcut: each frame becomes a SourceImage through a PNG round trip; fine at GIF sizes.
            let frame = try SourceImage(data: ImageCodec.encode(animation.frames[index].image, as: .png))
            animation.frames[index].image = try RenderPipeline.render(
                frame, recipe: recipe, assets: assets, final: true, flattenFor: type)
        }
        return try animation.encoded(as: type)
    }

    /// A HEIC or JPEG with the source gain map rebuilt from the edited HDR render, or `nil`
    /// when the source has none (or Core Image declines), so the caller writes SDR.
    private static func gainMapped(
        _ source: SourceImage, recipe: EditRecipe, assets: any AssetStore, as type: UTType, quality: Double?,
        properties: [String: Any]
    ) throws -> Data? {
        guard source.hasGainMap, type.conforms(to: .heic) || type.conforms(to: .jpeg), let hdrSource = source.hdrVariant() else {
            return nil
        }
        let sdr = try RenderPipeline.composite(source, recipe: recipe, assets: assets, final: true, flattenFor: type)
        let hdr = try RenderPipeline.composite(hdrSource, recipe: recipe, assets: assets, final: true, flattenFor: type)
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr.image.cropped(to: hdr.extent), qualityKey: quality ?? ImageCodec.defaultQuality(for: type),
        ]
        let image = sdr.image.cropped(to: sdr.extent).settingProperties(properties)
        let context = RenderPipeline.context
        return type.conforms(to: .heic)
            ? context.heifRepresentation(of: image, format: .RGBA8, colorSpace: source.colorSpace, options: options)
            : context.jpegRepresentation(of: image, colorSpace: source.colorSpace, options: options)
    }
}

// MARK: - Export

/// Formats offered by Export.
nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case png, jpeg, heic, avif, tiff, psd, jp2, exr, gif
    var id: String { rawValue }
    var title: String {
        switch self {
        case .jp2: "JPEG 2000"
        case .exr: "OpenEXR"
        case .psd: "Photoshop"
        default: rawValue.uppercased()
        }
    }
    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .avif: UTType("public.avif") ?? UTType(importedAs: "public.avif")
        case .tiff: .tiff
        case .psd: .psd
        case .jp2: UTType("public.jpeg-2000") ?? UTType(importedAs: "public.jpeg-2000")
        case .exr: UTType("com.ilm.openexr-image") ?? UTType(importedAs: "com.ilm.openexr-image")
        case .gif: .gif
        }
    }
    var isLossy: Bool { ImageCodec.isLossy(type) }
    /// The formats this Mac can write (Photoshop files are written by ``PSDWriter``).
    static var available: [ExportFormat] { allCases.filter { $0 == .psd || ImageCodec.canWrite($0.type) } }
}

/// Everything Export asks: format, quality, size and metadata. Also the batch preset format.
nonisolated struct ExportOptions: Codable, Equatable, Sendable {
    nonisolated enum Size: Codable, Equatable, Sendable {
        case original
        /// Long edge in pixels; never enlarges.
        case longEdge(Int)
        /// 100 = unchanged.
        case percent(Double)
        /// The largest file at most this many bytes: lower quality first, then fewer pixels.
        case maxBytes(Int)
    }

    var format: ExportFormat = .png
    /// 0…1, for lossy formats.
    var quality = 0.9
    var size: Size = .original
    var stripMetadata = false
}

nonisolated extension ImageSaver {
    /// The bytes Export writes for `options`. Size modes work on the cropped output, so one
    /// set of options fits images of any size (batch export).
    static func export(_ source: SourceImage, recipe: EditRecipe, assets: any AssetStore, options: ExportOptions) throws -> Data {
        var recipe = recipe
        if options.stripMetadata { recipe.stripMetadata = true }
        if options.format == .psd { return try PSDWriter.layeredPSD(source: source, recipe: recipe, assets: assets) }
        let type = options.format.type
        let quality = options.format.isLossy ? options.quality : nil
        let geometry = ImageGeometry(sourceSize: source.pixelSize, recipe: recipe)
        let output = PixelSize(geometry.outputSize)
        switch options.size {
        case .original: break
        case .longEdge(let edge): recipe.resize = output.fitting(maxEdge: edge)
        case .percent(let percent): recipe.resize = output.scaled(percent: percent)
        case .maxBytes(let budget):
            return try data(within: budget, source: source, recipe: recipe, assets: assets, as: type, quality: quality)
        }
        if recipe.resize == PixelSize(geometry.croppedSize) { recipe.resize = nil }
        return try data(for: source, recipe: recipe, assets: assets, as: type, quality: quality)
    }

    /// The largest encoding of at most `budget` bytes: a binary search on quality, then, if
    /// even the lowest quality is too big (or the format is lossless), fewer pixels.
    static func data(
        within budget: Int, source: SourceImage, recipe: EditRecipe, assets: any AssetStore, as type: UTType, quality: Double?
    ) throws -> Data {
        var recipe = recipe
        let properties = ImageCodec.propertiesForSaving(source.properties, strip: recipe.stripMetadata)
        var smallest: Data?
        for _ in 0..<4 {
            let image = try RenderPipeline.render(source, recipe: recipe, assets: assets, final: true, flattenFor: type)
            func attempt(_ q: Double?) throws -> Data {
                let data = try ImageCodec.encode(image, as: type, quality: q, properties: properties)
                if data.count < smallest?.count ?? .max { smallest = data }
                return data
            }
            let first = try attempt(quality)
            if first.count <= budget { return first }
            if let top = quality {
                var best: Data?
                var low = 0.02
                var high = top
                for _ in 0..<8 {
                    let mid = (low + high) / 2
                    let data = try attempt(mid)
                    if data.count <= budget { (best, low) = (data, mid) } else { high = mid }
                }
                if let best { return best }
            }
            // Bytes scale with area, so shrink the edge by the square root of the overshoot.
            let current = PixelSize(width: image.width, height: image.height)
            let ratio = (Double(budget) / Double(smallest?.count ?? first.count)).squareRoot() * 0.95
            recipe.resize = current.fitting(maxEdge: max(16, Int(Double(max(image.width, image.height)) * ratio)))
        }
        guard let smallest else { throw FolioError("Couldn’t make a file that small.") }
        return smallest
    }
}
