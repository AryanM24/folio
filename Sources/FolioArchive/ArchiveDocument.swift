import FolioKit
public import SwiftUI
public import UniformTypeIdentifiers

/// A zip, tar, 7z, rar or disk image, opened as a viewer.
///
/// Like `MediaDocument`, it holds **nothing**: archives can be gigabytes, so the view reads
/// the file URL from `@Environment(\.documentConfiguration)` and lists it with libarchive.
/// The original is never rewritten. Mount it with `DocumentGroup(viewing: ArchiveDocument.self)`.
public final class ArchiveDocument: ReferenceFileDocument {
    public typealias Snapshot = Void

    public nonisolated static var readableContentTypes: [UTType] { FileKind.archive.readableTypes }

    /// Opening is O(1): the bytes stay on disk.
    public nonisolated init(configuration: ReadConfiguration) throws {}

    public func snapshot(contentType: UTType) throws {}

    public nonisolated func fileWrapper(snapshot: Void, configuration: WriteConfiguration) throws -> FileWrapper {
        if let original = configuration.existingFile { return original }
        throw FolioError("Folio doesn't change archives in place. Extract or convert to make a new file.")
    }
}

/// The archive window. A placeholder until the 0.3 listing (entries, Quick Look, Extract) lands.
public struct ArchiveView: View {
    let document: ArchiveDocument

    public init(document: ArchiveDocument) { self.document = document }

    public var body: some View {
        ContentUnavailableView(
            "Archive", systemImage: FileKind.archive.symbol, description: Text("Browsing archives is coming in Folio 0.3."))
    }
}
