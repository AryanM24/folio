import FolioKit
import Foundation

/// A layered Photoshop file per Adobe's spec (raw channels, layer names, user masks).
// Phase 0 stub: the signature is the contract; WP6 fills in the body.
nonisolated enum PSDWriter {
    static func layeredPSD(source: SourceImage, recipe: EditRecipe, assets: any AssetStore) throws -> Data {
        throw FolioError("Folio can't write layered Photoshop files yet.")
    }
}
