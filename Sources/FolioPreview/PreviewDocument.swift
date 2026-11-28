import FolioKit
public import SwiftUI
public import UniformTypeIdentifiers

/// A file Folio shows but can't edit (Pages, Numbers, Keynote, PowerPoint, fonts, 3D,
/// Illustrator, EPS), opened as a viewer.
///
/// It holds **nothing**, like `MediaDocument`: the view reads the file URL from
/// `@Environment(\.documentConfiguration)` and hands it to Quick Look. The original is never
/// rewritten. Mount it with `DocumentGroup(viewing: PreviewDocument.self)`.
public final class PreviewDocument: ReferenceFileDocument {
    public typealias Snapshot = Void

    public nonisolated static var readableContentTypes: [UTType] { FileKind.preview.readableTypes }

    /// Opening is O(1): the bytes stay on disk.
    public nonisolated init(configuration: ReadConfiguration) throws {}

    public func snapshot(contentType: UTType) throws {}

    public nonisolated func fileWrapper(snapshot: Void, configuration: WriteConfiguration) throws -> FileWrapper {
        if let original = configuration.existingFile { return original }
        throw FolioError("Folio only previews this file. Use Convert to save it in another format.")
    }
}
