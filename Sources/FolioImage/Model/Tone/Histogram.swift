import CoreImage

/// Per-channel histograms from `CIAreaHistogram`.
// Phase 0 stub: the signature is the contract; WP3 fills in the body.
nonisolated struct Histogram: Equatable, Sendable {
    static let bins = 256

    /// `bins` values each, normalized so the tallest bin of all four is 1. Empty = none.
    var red: [Float] = []
    var green: [Float] = []
    var blue: [Float] = []
    var luminance: [Float] = []

    static func compute(_ image: CIImage) -> Histogram {
        Histogram()
    }
}
