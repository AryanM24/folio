import Foundation

/// A saved look: any subset of the tone settings, applied to other images (and batches).
/// Geometry and content are never part of a preset, so it fits any image size.
// Phase 0 stub: the signature is the contract; WP3 fills in the body.
nonisolated struct ImagePreset: Codable, Equatable, Sendable, Identifiable {
    static let version = 1

    var version = Self.version
    var id = UUID()
    var name: String
    /// `nil` fields leave the recipe's own value alone.
    var adjustments: Adjustments?
    var tone: ToneSpec?
    var filter: FilterPreset?
    var filterStrength: Double?
    /// LUT files the tone refers to, so a preset is self-contained.
    var assets: [AssetID: Data] = [:]

    /// `recipe` with this preset's settings in place of its own; LUTs go into `store`.
    func applied(to recipe: EditRecipe, store: any AssetStore) throws -> EditRecipe {
        recipe
    }
}
