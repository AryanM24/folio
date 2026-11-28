import FolioKit
import Foundation
import Synchronization

/// The SHA-256 (lowercase hex) of an encoded blob: PNG/HEIC pixels, a `.cube` file, a
/// float field. Recipes hold these, never pixels, so undo and sessions stay small.
typealias AssetID = String

/// Immutable, content-addressed blobs that a recipe refers to by ``AssetID``.
///
/// Putting the same bytes twice returns the same ID. The session store and the
/// `.folioimage` package persist them; rendering only reads.
nonisolated protocol AssetStore: Sendable {
    /// The bytes for `id`. Throws when the store doesn't have them.
    func data(_ id: AssetID) throws -> Data
    /// Store `data` and return its ID.
    @discardableResult func put(_ data: Data) throws -> AssetID
}

/// An ``AssetStore`` in memory: each open document has one.
nonisolated final class InMemoryAssetStore: AssetStore {
    private let blobs: Mutex<[AssetID: Data]>

    init(_ blobs: [AssetID: Data] = [:]) { self.blobs = Mutex(blobs) }

    func data(_ id: AssetID) throws -> Data {
        guard let data = blobs.withLock({ $0[id] }) else { throw FolioError("A layer's image data is missing from this document.") }
        return data
    }

    @discardableResult func put(_ data: Data) -> AssetID {
        let id = EditSessionStore.key(for: data)
        blobs.withLock { $0[id] = data }
        return id
    }

    /// Every blob, for writing sessions and packages.
    var all: [AssetID: Data] { blobs.withLock { $0 } }
}
