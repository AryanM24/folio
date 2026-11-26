import FolioKit
public import SwiftUI
public import UniformTypeIdentifiers

/// An audio or video file, opened as a viewer.
///
/// Media files can be gigabytes, so this type deliberately holds **nothing**: it never
/// touches `configuration.file.regularFileContents`. `MediaEditorView` reads the file URL
/// from `@Environment(\.documentConfiguration)` and streams it with AVFoundation.
///
/// The original is never rewritten. Every edit (trim, rotate, re-encode…) produces a new
/// file through Export. Mount it with `DocumentGroup(viewing: MediaDocument.self)`.
/// If it is mounted in an editable group anyway, the document never registers an undo,
/// so it is never dirty and autosave never runs; `fileWrapper` returns the original
/// file unchanged when AppKit asks (e.g. "Duplicate"), and throws otherwise.
public final class MediaDocument: ReferenceFileDocument {
    /// No state to snapshot: the document is the file on disk.
    public typealias Snapshot = Void

    public nonisolated static var readableContentTypes: [UTType] { FileKind.media.readableTypes }

    /// When the document was created, to measure time-to-first-frame of the window.
    nonisolated let openedAt = ContinuousClock.now

    /// An empty document. Only reachable from an editable `DocumentGroup`'s File > New;
    /// the view shows a "choose a file" placeholder.
    public nonisolated init() {}

    /// Opening is O(1): the bytes stay on disk.
    public nonisolated init(configuration: ReadConfiguration) throws {}

    public func snapshot(contentType: UTType) throws {}

    public nonisolated func fileWrapper(snapshot: Void, configuration: WriteConfiguration) throws -> FileWrapper {
        if let original = configuration.existingFile { return original }
        throw FolioError("Folio doesn't change media files in place. Use Export to save a new copy.")
    }
}
