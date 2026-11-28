import FolioKit
import Foundation

/// The `.folioimage` package: a directory with `document.json` (the recipe),
/// `original.<ext>`, `assets/<id>` and `preview.heic` for Finder and Quick Look.
// Phase 0 stub: the signature is the contract; WP6 fills in the body.
nonisolated struct FolioImagePackage: Sendable {
    static let typeIdentifier = "app.folio.image"

    var recipe: EditRecipe
    var original: Data
    var originalTypeIdentifier: String
    var assets: [AssetID: Data] = [:]
    /// Flattened render for thumbnails.
    var preview: Data?
}

nonisolated extension FolioImagePackage {
    init(fileWrapper: FileWrapper) throws {
        throw FolioError("Folio can't open Folio Image packages yet.")
    }

    func fileWrapper() throws -> FileWrapper {
        throw FolioError("Folio can't save Folio Image packages yet.")
    }
}
