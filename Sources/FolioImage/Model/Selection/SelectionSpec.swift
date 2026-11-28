import CoreGraphics
import Foundation

/// A selection as data: shapes combined in order, then refined. It is both the live
/// selection in the editor and what a layer mask stores (`MaskSource.selection`).
/// `SelectionRenderer` turns it into a mask; pixel-based shapes (wand, color range,
/// subject, sky) are recomputed from the image and cached in memory, never stored.
///
/// Coordinates are source pixels of the oriented original, top-left origin.
/// Contract type for 0.3: frozen after Phase 0.
nonisolated struct SelectionSpec: Codable, Equatable, Sendable {
    nonisolated enum Mode: String, Codable, Sendable, CaseIterable { case add, subtract, intersect }

    nonisolated enum Shape: Codable, Equatable, Sendable {
        case rect(CGRect)
        case ellipse(CGRect)
        /// Lasso and polygon lasso: a closed polygon through these points.
        case polygon([CGPoint])
        /// A Bézier path (pen tool, converted vector masks).
        case path(VectorPath)
        /// Magic wand: pixels similar to the seed (tolerance 0…1, in Lab ΔE terms).
        case wand(seed: CGPoint, tolerance: Double, contiguous: Bool, sampleAllLayers: Bool)
        /// Select color range: every pixel near `color`, softly (fuzziness 0…1).
        case colorRange(RGBA, fuzziness: Double)
        /// Vision foreground instances, or every subject when `nil`.
        case subject(instances: [Int]?)
        /// One person (0-based), or all people when `nil`.
        case people(index: Int?)
        case sky
        case all
        /// A saved selection in the asset store (grayscale, white = selected).
        case pixels(AssetID)
    }

    nonisolated struct Op: Codable, Equatable, Sendable {
        var shape: Shape
        var mode: Mode = .add
    }

    /// Applied in order to an empty selection. The first `.add` starts it.
    var ops: [Op] = []
    /// Gaussian feather radius in source pixels.
    var feather = 0.0
    /// Grow (> 0) or shrink (< 0) the edge, in source pixels.
    var expand = 0.0
    /// Rounds jagged corners, radius in source pixels.
    var smooth = 0.0
    /// Edge-aware refinement radius (hair, fur) guided by the image, in source pixels.
    var refineEdge = 0.0
    var inverted = false

    init(ops: [Op] = []) { self.ops = ops }

    init(_ shape: Shape) { ops = [Op(shape: shape)] }

    var isEmpty: Bool { ops.isEmpty && !inverted }

    /// This selection with `shape` combined in.
    func adding(_ shape: Shape, mode: Mode = .add) -> SelectionSpec {
        var copy = self
        copy.ops.append(Op(shape: shape, mode: mode))
        return copy
    }
}
