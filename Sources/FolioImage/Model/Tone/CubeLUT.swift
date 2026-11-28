import FolioKit
import Foundation

/// An Adobe `.cube` LUT (1D or 3D), parsed.
// Phase 0 stub: the signature is the contract; WP3 fills in the body.
nonisolated struct CubeLUT: Equatable, Sendable {
    var title: String?
    /// 1 or 3.
    var dimension: Int
    /// Entries per axis.
    var size: Int
    var domainMin: [Double]
    var domainMax: [Double]
    /// RGB triples, red varying fastest.
    var values: [Float]

    init(data: Data) throws {
        throw FolioError("Folio can't read LUT files yet.")
    }
}
