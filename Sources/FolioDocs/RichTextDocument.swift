import AppKit
public import FolioKit
import OSLog
public import SwiftUI
public import UniformTypeIdentifiers

nonisolated private let log = Log.make("Docs")

/// A rich-text document: Word, RTF, RTFD, OpenDocument, HTML, web archive or Word 97.
///
/// The text lives in one `NSTextStorage` that the editor's text view edits directly,
/// so there is no copy to keep in sync and every keystroke goes through the text
/// view's undo registration, which is what marks the document edited and triggers
/// autosave. A file is always saved back in the format it was opened in.
public final class RichTextDocument: ReferenceFileDocument {
    public typealias Snapshot = DocumentSnapshot

    public nonisolated static var readableContentTypes: [UTType] { FileKind.document.readableTypes }

    /// The live text. The editor attaches its layout manager to it.
    let storage: NSTextStorage
    /// Paper and margins, saved into the file's page setup.
    @Published private(set) var page: PageSetup
    /// Document attributes read from the file (title, author, …), written back on save.
    let attributes: DocumentCodec.Attributes
    /// Format the file was opened in. New documents are Word files.
    let format: DocFormat
    /// When reading began, for the "open to first paint" log line.
    let openedAt: Date

    /// A new, empty document.
    public nonisolated init() {
        storage = NSTextStorage()
        page = PageSetup()
        attributes = [:]
        format = .docx
        openedAt = Date()
    }

    /// The bytes of a new, empty Word document, for creating a real file on disk before
    /// opening it (the workspace's "Start something" tiles) rather than an untitled window.
    public nonisolated static func emptyFileData() -> Data {
        DocxWriter.data(from: NSAttributedString(), page: PageSetup())
    }

    public nonisolated init(configuration: ReadConfiguration) throws {
        let start = Date()
        openedAt = start
        let format = DocFormat.format(for: configuration.contentType) ?? .rtf
        let (text, attributes) = try DocumentCodec.read(configuration.file, as: format)
        storage = NSTextStorage(attributedString: text)
        page = PageSetup(attributes: attributes)
        self.attributes = attributes
        self.format = format
        log.info(
            "Read \(format.rawValue, privacy: .public) document, \(text.length) characters, in \(Int(Date().timeIntervalSince(start) * 1000)) ms"
        )
    }

    /// Copies the text so the background save encodes a stable value while typing
    /// continues. Copying is linear but cheap next to encoding.
    public nonisolated func snapshot(contentType: UTType) throws -> DocumentSnapshot {
        readDuringSave { DocumentSnapshot(text: NSAttributedString(attributedString: storage), attributes: attributes, page: page) }
    }

    public nonisolated func fileWrapper(snapshot: DocumentSnapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let format = DocFormat.format(for: configuration.contentType).flatMap { DocFormat.editable.contains($0) ? $0 : nil } ?? .docx
        return try DocumentCodec.fileWrapper(snapshot.text, attributes: snapshot.attributes, page: snapshot.page, as: format)
    }

    /// Changes paper or margins as an undoable edit, so it autosaves like typing does.
    func setPage(_ newValue: PageSetup, undoManager: UndoManager?) {
        let old = page
        guard old != newValue else { return }
        page = newValue
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.setPage(old, undoManager: undoManager) }
        }
        undoManager?.setActionName("Page Setup")
    }
}

/// An immutable copy of a document taken on the main thread and encoded in the
/// background by `fileWrapper(snapshot:configuration:)`.
public nonisolated struct DocumentSnapshot: @unchecked Sendable {
    // @unchecked: every stored value is an immutable copy made in `snapshot(contentType:)`
    // and never mutated afterwards.
    let text: NSAttributedString
    let attributes: DocumentCodec.Attributes
    let page: PageSetup
}
