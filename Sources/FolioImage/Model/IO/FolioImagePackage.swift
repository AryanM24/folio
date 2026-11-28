import FolioKit
import Foundation
import UniformTypeIdentifiers

/// The `.folioimage` package: a directory with `document.json` (the recipe and the
/// original type), `original.<ext>`, `assets/<id>` and `preview.heic` for Finder and Quick Look.
nonisolated struct FolioImagePackage: Sendable {
    static let typeIdentifier = "app.folio.image-document"

    var recipe: EditRecipe
    var original: Data
    var originalTypeIdentifier: String
    var assets: [AssetID: Data] = [:]
    /// Flattened render for thumbnails.
    var preview: Data?

    /// `document.json`.
    private struct Manifest: Codable {
        var version = EditRecipe.version
        var originalType: String
        var recipe: EditRecipe
    }
}

nonisolated extension FolioImagePackage {
    init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isDirectory, let children = fileWrapper.fileWrappers,
            let json = children["document.json"]?.regularFileContents
        else { throw FolioError("This Folio Image is damaged: its document.json is missing.") }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: json) } catch {
            throw FolioError("This Folio Image is damaged: its document.json couldn’t be read.")
        }
        guard manifest.version <= EditRecipe.version else {
            throw FolioError("This Folio Image was made by a newer version of Folio. Update Folio to open it.")
        }
        guard let original = children.first(where: { $0.key.hasPrefix("original.") })?.value.regularFileContents else {
            throw FolioError("This Folio Image is damaged: its original image is missing.")
        }
        var assets: [AssetID: Data] = [:]
        for (name, wrapper) in children["assets"]?.fileWrappers ?? [:] {
            let id = (name as NSString).deletingPathExtension
            // Content-addressed: a blob whose hash does not match its name is damaged, so drop it.
            if let data = wrapper.regularFileContents, EditSessionStore.key(for: data) == id { assets[id] = data }
        }
        self.init(
            recipe: manifest.recipe, original: original, originalTypeIdentifier: manifest.originalType, assets: assets,
            preview: children["preview.heic"]?.regularFileContents)
    }

    func fileWrapper() throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = try encoder.encode(Manifest(originalType: originalTypeIdentifier, recipe: recipe))
        let ext = UTType(originalTypeIdentifier)?.preferredFilenameExtension ?? "bin"
        var children: [String: FileWrapper] = [
            "document.json": FileWrapper(regularFileWithContents: manifest),
            "original.\(ext)": FileWrapper(regularFileWithContents: original),
            "assets": FileWrapper(directoryWithFileWrappers: assets.mapValues { FileWrapper(regularFileWithContents: $0) }),
        ]
        if let preview { children["preview.heic"] = FileWrapper(regularFileWithContents: preview) }
        return FileWrapper(directoryWithFileWrappers: children)
    }
}
