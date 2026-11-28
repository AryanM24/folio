import FolioKit
public import SwiftUI
import Synchronization
public import UniformTypeIdentifiers

nonisolated private let log = Log.make("Image")

/// An image file: the untouched original plus an ``EditRecipe``.
///
/// Saving re-renders the original with the recipe at full resolution (in the
/// background, inside `fileWrapper`), so autosaving never compounds compression.
/// An unedited file saves back byte-for-byte. See docs/editors/images.md.
public final class ImageDocument: ReferenceFileDocument {
    public nonisolated static var readableContentTypes: [UTType] { FileKind.image.readableTypes }

    /// Formats this Mac can encode. WebP opens read-only; edits are kept with Export As.
    public nonisolated static var writableContentTypes: [UTType] {
        FileKind.image.readableTypes.filter(ImageCodec.canWrite)
    }

    /// Cheap, immutable capture of the document for a background save.
    public struct Snapshot: Sendable {
        let source: SourceImage
        let recipe: EditRecipe
        let assets: any AssetStore
        let session: SessionKey
    }

    /// The edits. Change them through ``setRecipe(_:actionName:undoManager:)`` so undo
    /// and autosave see every change; `objectWillChange` fires first.
    ///
    /// SwiftUI requires documents to be `Sendable` and calls `init` and `fileWrapper`
    /// off the main actor, so the one mutable value lives behind a lock rather than in
    /// a `@Published` property.
    var recipe: EditRecipe { storage.withLock { $0 } }
    private let storage: Mutex<EditRecipe>
    /// The original as opened (or restored from an edit session).
    let source: SourceImage
    /// Pixel blobs the recipe's layers refer to (pasted images, fills, LUTs).
    let assets: any AssetStore = InMemoryAssetStore()
    /// The key of the last edit session written for this document.
    let session: SessionKey

    /// A new, blank white canvas to draw on.
    public nonisolated init() {
        // Proof for `try!`: a fixed-size sRGB bitmap always encodes and decodes as PNG
        // (covered by `blankDocumentIsWhiteCanvas` in the tests).
        source = try! SourceImage(data: Self.blankPNG(), typeHint: .png)
        storage = Mutex(EditRecipe())
        session = SessionKey(nil)
    }

    public nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw FolioError("This image couldn't be read. It may be a folder or an alias that no longer points anywhere.")
        }
        if let restored = EditSessionStore.shared.restore(fileData: data),
            let original = try? SourceImage(data: restored.original, typeHint: UTType(restored.originalTypeIdentifier))
        {
            source = original
            storage = Mutex(restored.recipe)
            session = SessionKey(restored.key)
            log.info("Restored an edit session for an image")
        } else {
            source = try SourceImage(data: data, typeHint: configuration.contentType)
            storage = Mutex(EditRecipe())
            session = SessionKey(nil)
        }
    }

    public nonisolated func snapshot(contentType: UTType) throws -> Snapshot {
        readDuringSave { Snapshot(source: source, recipe: recipe, assets: assets, session: session) }
    }

    public nonisolated func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let type = configuration.contentType
        let data = try ImageSaver.data(for: snapshot.source, recipe: snapshot.recipe, assets: snapshot.assets, as: type)
        Self.updateSession(snapshot: snapshot, output: data)
        return FileWrapper(regularFileWithContents: data)
    }

    /// Replace the recipe as one undoable step named `actionName`.
    @MainActor
    func setRecipe(_ new: EditRecipe, actionName: String, undoManager: UndoManager?) {
        let old = recipe
        guard new != old else { return }
        objectWillChange.send()
        storage.withLock { $0 = new }
        undoManager?.registerUndo(withTarget: self) { document in
            document.setRecipe(old, actionName: actionName, undoManager: undoManager)
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: Helpers

    /// Keep the content-addressed edit session in step with what was just written.
    private nonisolated static func updateSession(snapshot: Snapshot, output: Data) {
        let store = EditSessionStore.shared
        let previous = snapshot.session.value
        var current: String?
        if !snapshot.recipe.isIdentity, !snapshot.recipe.stripMetadata, output != snapshot.source.data {
            do {
                current = try store.record(
                    output: output, original: snapshot.source.data,
                    originalTypeIdentifier: snapshot.source.type.identifier, recipe: snapshot.recipe)
            } catch {
                // Not fatal: the file itself saved; only reopen-and-keep-editing is lost.
                log.error("Couldn't record the image edit session: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let previous, previous != current { store.remove(key: previous) }
        snapshot.session.value = current
    }

    nonisolated static func blankPNG(width: Int = 1600, height: Int = 1000) -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return Data() }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return Data() }
        return (try? ImageCodec.encode(image, as: .png)) ?? Data()
    }
}

/// The current edit-session key, shared between the document and its background saves.
nonisolated final class SessionKey: Sendable {
    private let storage: Mutex<String?>
    init(_ value: String?) { storage = Mutex(value) }
    var value: String? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
