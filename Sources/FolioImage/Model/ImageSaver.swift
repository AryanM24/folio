import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Produces the bytes written to disk for a save or an export.
nonisolated enum ImageSaver {
    /// The file contents for `recipe` applied to `source`, encoded as `type`.
    ///
    /// - Nothing changed: the original bytes, untouched (no recompression, ever).
    /// - Only "remove metadata" changed: a lossless metadata rewrite.
    /// - Otherwise: a full-resolution render, encoded with the original's metadata
    ///   (minus orientation, which rendering applied) unless the user stripped it.
    static func data(for source: SourceImage, recipe: EditRecipe, as type: UTType, quality: Double? = nil) throws -> Data {
        let sameFormat = type == source.type && quality == nil
        if sameFormat, recipe.isIdentity { return source.data }
        if sameFormat, !recipe.changesPixels, source.frameCount == 1 {
            return try ImageCodec.strippingMetadata(source.data)
        }
        let image = try RenderPipeline.render(source, recipe: recipe, final: true, flattenFor: type)
        let properties = ImageCodec.propertiesForSaving(source.properties, strip: recipe.stripMetadata)
        return try ImageCodec.encode(image, as: type, quality: quality, properties: properties)
    }
}
