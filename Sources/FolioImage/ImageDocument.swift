import FolioKit
public import SwiftUI
import Synchronization
public import UniformTypeIdentifiers

nonisolated private let log = Log.make("Image")

/// An image file: the untouched original plus an ``EditRecipe`` and the assets it refers to.
///
/// Saving re-renders the original with the recipe at full resolution (in the
/// background, inside `fileWrapper`), so autosaving never compounds compression.
/// An unedited file saves back byte-for-byte. Saving as a `.folioimage` package keeps
/// the original, recipe and assets in the file instead. See docs/editors/images.md.
public final class ImageDocument: ReferenceFileDocument {
    /// SVG opens rasterized (see `SourceImage`); `.folioimage` packages open with their layers.
    public nonisolated static var readableContentTypes: [UTType] {
        FileKind.image.readableTypes + [.folioImageDocument, .svg]
    }

    /// Formats this Mac can encode, plus the package. WebP opens read-only; edits are kept with Export As.
    public nonisolated static var writableContentTypes: [UTType] {
        FileKind.image.readableTypes.filter(ImageCodec.canWrite) + [.folioImageDocument]
    }

    /// Cheap, immutable capture of the document for a background save.
    public struct Snapshot: Sendable {
        let source: SourceImage
        let recipe: EditRecipe
        let assets: InMemoryAssetStore
        let session: SessionKey
    }

    /// The edits. Change them through ``setRecipe(_:actionName:undoManager:)`` so undo
    /// and autosave see every change; `objectWillChange` fires first.
    ///
    /// SwiftUI requires documents to be `Sendable` and calls `init` and `fileWrapper`
    /// off the main actor, so the mutable values live behind locks rather than in
    /// `@Published` properties.
    var recipe: EditRecipe { storage.withLock { $0 } }
    private let storage: Mutex<EditRecipe>
    /// The original as opened (or restored from an edit session or package). Replaced only
    /// by ``replace(source:recipe:)`` (Upscale).
    var source: SourceImage { sourceStorage.withLock { $0 } }
    private let sourceStorage: Mutex<SourceImage>
    /// Pixel blobs the recipe layers refer to (pasted images, fills, patches, masks, LUTs).
    /// Saved in the edit session or the package, and restored with them.
    let assets: InMemoryAssetStore
    /// The key of the last edit session written for this document.
    let session: SessionKey

    /// A new, blank white canvas to draw on.
    public nonisolated init() {
        // Proof for `try!`: a fixed-size sRGB bitmap always encodes and decodes as PNG
        // (covered by `blankDocumentIsWhiteCanvas` in the tests).
        sourceStorage = Mutex(try! SourceImage(data: Self.blankPNG(), typeHint: .png))
        storage = Mutex(EditRecipe())
        assets = InMemoryAssetStore()
        session = SessionKey(nil)
    }

    public nonisolated init(configuration: ReadConfiguration) throws {
        let file = configuration.file
        if file.isDirectory {
            let package = try FolioImagePackage(fileWrapper: file)
            sourceStorage = Mutex(try SourceImage(data: package.original, typeHint: UTType(package.originalTypeIdentifier)))
            storage = Mutex(package.recipe)
            assets = InMemoryAssetStore(package.assets)
            session = SessionKey(nil)
            return
        }
        guard let data = file.regularFileContents else {
            throw FolioError("This image couldn’t be read. It may be a folder or an alias that no longer points anywhere.")
        }
        if let restored = EditSessionStore.shared.restore(fileData: data),
            let original = try? SourceImage(data: restored.original, typeHint: UTType(restored.originalTypeIdentifier))
        {
            sourceStorage = Mutex(original)
            storage = Mutex(restored.recipe)
            assets = InMemoryAssetStore(restored.assets)
            session = SessionKey(restored.key)
            log.info("Restored an edit session for an image")
        } else {
            sourceStorage = Mutex(try SourceImage(data: data, typeHint: configuration.contentType))
            storage = Mutex(EditRecipe())
            assets = InMemoryAssetStore()
            session = SessionKey(nil)
        }
    }

    public nonisolated func snapshot(contentType: UTType) throws -> Snapshot {
        readDuringSave { Snapshot(source: source, recipe: recipe, assets: assets, session: session) }
    }

    public nonisolated func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let type = configuration.contentType
        if type.conforms(to: .folioImageDocument) { return try Self.package(for: snapshot).fileWrapper() }
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

    /// Swap the base image and the recipe together (Upscale bakes the edits into the new
    /// base). Not undoable by itself: the caller registers the undo, so it can re-render.
    @MainActor
    func replace(source new: SourceImage, recipe newRecipe: EditRecipe) {
        objectWillChange.send()
        sourceStorage.withLock { $0 = new }
        storage.withLock { $0 = newRecipe }
    }

    // MARK: Helpers

    /// Keep the content-addressed edit session in step with what was just written.
    ///
    /// Guides-only edits save the original bytes unchanged, so the session (keyed by those
    /// bytes) is what keeps them. Privacy: stripping metadata or redacting writes no session,
    /// since its pristine original would still hold what the user removed.
    nonisolated static func updateSession(snapshot: Snapshot, output: Data, store: EditSessionStore = .shared) {
        let previous = snapshot.session.value
        let recipe = snapshot.recipe
        var current: String?
        if !recipe.isIdentity, !recipe.stripMetadata, !recipe.containsRedaction {
            do {
                current = try store.record(
                    output: output, original: snapshot.source.data, originalTypeIdentifier: snapshot.source.type.identifier,
                    recipe: recipe, assets: EditSessionStore.referenced(snapshot.assets.all, by: recipe))
            } catch {
                // Not fatal: the file itself saved; only reopen-and-keep-editing is lost.
                log.error("Couldn’t record the image edit session: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let previous, previous != current { store.remove(key: previous) }
        snapshot.session.value = current
    }

    /// The `.folioimage` contents for `snapshot`. With a redaction the package holds only the
    /// flattened render (and an empty recipe), so nothing under the redaction can be recovered.
    nonisolated static func package(for snapshot: Snapshot) throws -> FolioImagePackage {
        let (source, recipe, assets) = (snapshot.source, snapshot.recipe, snapshot.assets)
        let preview = try? previewData(source: source, recipe: recipe, assets: assets)
        guard !recipe.containsRedaction else {
            let flat = try ImageSaver.data(for: source, recipe: recipe, assets: assets, as: .png)
            return FolioImagePackage(recipe: EditRecipe(), original: flat, originalTypeIdentifier: UTType.png.identifier, preview: preview)
        }
        return FolioImagePackage(
            recipe: recipe, original: source.data, originalTypeIdentifier: source.type.identifier,
            assets: EditSessionStore.referenced(assets.all, by: recipe), preview: preview)
    }

    /// A small flattened render for Finder and Quick Look thumbnails.
    nonisolated static func previewData(source: SourceImage, recipe: EditRecipe, assets: any AssetStore) throws -> Data {
        let scale = min(1, 1024 / max(source.pixelSize.width, source.pixelSize.height))
        let image = try RenderPipeline.render(source, recipe: recipe, assets: assets, scale: scale, final: true)
        return try ImageCodec.encode(image, as: ImageCodec.canWrite(.heic) ? .heic : .png)
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
