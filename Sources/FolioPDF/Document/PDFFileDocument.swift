import FolioKit
import PDFKit
public import SwiftUI
public import UniformTypeIdentifiers

private nonisolated let log = Log.make("PDF")

/// A PDF open in Folio.
///
/// The live `PDFDocument` is the model: `PDFView` renders it directly and every edit
/// (annotations, page operations, form values) mutates it in place through the
/// window's undo manager, which is what triggers autosave (see docs/ARCHITECTURE.md).
///
/// ### Why the snapshot is a reference, not a copy
/// The architecture asks for cheap snapshots. `PDFDocument.copy()` is cheap but its
/// copy silently drops every annotation when serialised, and `dataRepresentation()`
/// on the main thread costs tens to hundreds of milliseconds on large or image-heavy
/// files. So the snapshot is a handle to the live document behind a lock
/// (``PDFAccess``). `fileWrapper` serialises in the background while holding the lock,
/// and every mutation Folio makes goes through ``PDFAccess/withLock(_:)`` too, so a
/// save never observes a half-applied edit. The main thread only ever waits when the
/// user edits during an in-flight save, and then only for that save to finish.
public final class PDFFileDocument: ReferenceFileDocument {
    /// What autosave serialises: the shared, locked document.
    public struct Snapshot: Sendable {
        let access: PDFAccess
    }

    public nonisolated static var readableContentTypes: [UTType] { FileKind.pdf.readableTypes }
    public nonisolated static var writableContentTypes: [UTType] { [.pdf] }

    /// Lock-guarded access to the document, shared with background writers.
    let access: PDFAccess

    /// When the bytes were parsed, for the "open to first paint" measurement in the log.
    let loadedAt: ContinuousClock.Instant

    /// The live document. Read it freely on the main actor; mutate it through
    /// ``PDFAccess/withLock(_:)`` (the editor model does this for you).
    var pdf: PDFDocument { access.pdf }

    /// A new document: one blank page in the user's paper size.
    public nonisolated init() {
        access = PDFAccess(PageFactory.blankDocument())
        loadedAt = .now
    }

    /// The bytes of a new PDF with one blank page in the user's paper size, for creating
    /// a real file on disk before opening it, the same content `init()` starts with.
    public nonisolated static func emptyFileData() -> Data {
        PageFactory.blankDocument().dataRepresentation() ?? Data()
    }

    /// Parses the file. `PDFDocument` is lazy, so this costs about the same for 5 pages
    /// as for 500: pages, text and thumbnails are decoded only when first shown.
    public nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let pdf = PDFDocument(data: data) else {
            throw FolioError("This file isn't a PDF, or it's damaged.")
        }
        guard !pdf.isLocked else {
            throw FolioError("This PDF is protected with a password. Folio can't open protected PDFs yet.")
        }
        access = PDFAccess(pdf)
        loadedAt = .now
    }

    /// Wraps an already parsed document (tests, previews).
    init(pdf: PDFDocument) {
        access = PDFAccess(pdf)
        loadedAt = .now
    }

    public nonisolated func snapshot(contentType: UTType) throws -> Snapshot {
        readDuringSave { Snapshot(access: access) }
    }

    public nonisolated func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let start = ContinuousClock.now
        let data = try snapshot.access.withLock { pdf in
            guard let data = pdf.dataRepresentation() else {
                throw FolioError("Folio couldn't write this PDF.")
            }
            return data
        }
        log.debug("Serialised \(data.count) bytes in \(ContinuousClock.now - start)")
        return FileWrapper(regularFileWithContents: data)
    }
}

/// A `PDFDocument` that may be touched from the main actor (edits) and a background
/// writer (autosave, export). PDFKit documents aren't thread-safe, so both sides hold
/// the same lock while they work. The lock is recursive because model helpers nest.
nonisolated final class PDFAccess: @unchecked Sendable {
    // @unchecked: every mutation (main actor) and every off-main read holds `lock`.
    // Main-actor reads skip it: the only writer is the main actor itself.
    private let lock = NSRecursiveLock()
    let pdf: PDFDocument

    init(_ pdf: PDFDocument) { self.pdf = pdf }

    /// Runs `body` with exclusive access to the document.
    func withLock<T>(_ body: (PDFDocument) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(pdf)
    }
}
