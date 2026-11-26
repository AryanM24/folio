import Foundation

/// Reads main-actor document state from inside `ReferenceFileDocument.snapshot(contentType:)`.
///
/// **Why this exists.** During autosave, AppKit asks for the snapshot on a background save
/// thread, not on the main thread. It does so while it *parks the main thread*: when a
/// document saves asynchronously, `NSDocument` blocks user interaction until the snapshot
/// is taken and `unblockUserInteraction()` is called (SwiftUI calls it right after
/// `snapshot`). So nothing on the main actor can run, or mutate the document, while this
/// closure runs, and reading main-actor state is race-free.
///
/// Swift can't see that guarantee. `MainActor.assumeIsolated` would trap on the save
/// thread (that crash is why this helper exists), and hopping to the main thread with
/// `DispatchQueue.main.sync` would deadlock, because the main thread is waiting for us.
///
/// Use it for exactly one thing, copying state into a value:
/// ```swift
/// public nonisolated func snapshot(contentType: UTType) throws -> Snapshot {
///     readDuringSave { Snapshot(workbook: workbook, values: engine.values) }
/// }
/// ```
/// Keep the closure to a copy. Do the expensive encoding in `fileWrapper(snapshot:)`.
public nonisolated func readDuringSave<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }
    // Global-actor-isolated and plain function types share a representation; the cast
    // only drops the compile-time isolation, which the parked main thread makes safe.
    return try withoutActuallyEscaping(body) { body in
        try unsafeBitCast(body, to: (() throws -> T).self)()
    }
}
