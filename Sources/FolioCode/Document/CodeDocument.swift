public import SwiftUI
public import UniformTypeIdentifiers
import FolioKit
import AppKit

/// A plain-text, Markdown or source file.
///
/// The text lives in the editor's `NSTextStorage` once a window is open (``liveText``);
/// before that, in ``loadedText``. Edits never copy the text into the document, which is
/// what keeps typing in a 10 MB file instant: only ``snapshot(contentType:)`` copies it, once
/// per autosave, and the encoding work happens in ``fileWrapper``.
///
/// Threading: SwiftUI makes document classes nonisolated (the protocol is Sendable). The
/// editor mutates state on the main thread. `snapshot` is called by NSDocument's background
/// writer during autosave, but NSDocument keeps the main thread blocked until the file
/// wrapper exists, so nothing mutates concurrently. Hence the unchecked conformance.
public final class CodeDocument: ReferenceFileDocument, @unchecked Sendable {
    public nonisolated struct Snapshot: Sendable {
        let text: String
        let format: TextFormat
    }

    public nonisolated static var readableContentTypes: [UTType] { FileKind.code.readableTypes }

    /// Encoding and line endings used when saving. Changed from the status bar, with undo.
    @Published public private(set) var format: TextFormat
    /// Chosen from the file name; the status bar can override it for this window.
    @Published public var language: Language
    /// Tabs or spaces, detected from the file. Not saved; it only shapes what Tab inserts.
    @Published var indent: IndentStyle

    /// The text as read from disk, until an editor takes over.
    private(set) var loadedText: String
    /// The editor's storage. Weak: the editor owns it, and if it goes away we fall back to
    /// the last text it reported in ``editorWillClose(text:)``.
    /// Read from `snapshot` off the main thread; see the threading note above.
    nonisolated(unsafe) weak var liveText: NSTextStorage?
    /// When the file started loading, for the "opened in N ms" log line.
    let openedAt = ContinuousClock.now
    let byteCount: Int

    public nonisolated init() {
        loadedText = ""
        format = .standard
        language = .plain
        indent = IndentStyle(usesTabs: false, width: Self.defaultTabWidth)
        byteCount = 0
    }

    public nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw FolioError("This file couldn’t be read. It may have been moved, or it may not be a text file.")
        }
        let decoded = TextCodec.decode(data)
        loadedText = decoded.text
        format = decoded.format
        byteCount = data.count
        let firstLine = decoded.text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        language = Language.detect(fileName: configuration.file.filename ?? configuration.file.preferredFilename,
                                   contentType: configuration.contentType, firstLine: firstLine)
        indent = IndentStyle.detect(in: decoded.text) ?? IndentStyle(usesTabs: false, width: Self.defaultTabWidth)
    }

    /// The Editor settings tab's tab width, for files with no indentation to detect.
    private nonisolated static var defaultTabWidth: Int {
        let width = UserDefaults.standard.integer(forKey: "code.tabWidth")
        return width > 0 ? width : 4
    }

    /// Current text. `NSTextStorage.string` returns an immutable copy, so it stays valid for
    /// the background writer after editing resumes.
    var text: String { liveText?.string ?? loadedText }

    /// Called when the editor tears down, so later snapshots still see the latest text.
    @MainActor func editorWillClose(text: String) { loadedText = text }

    public nonisolated func snapshot(contentType: UTType) throws -> Snapshot {
        readDuringSave { Snapshot(text: text, format: format) }
    }

    public nonisolated func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try TextCodec.encode(snapshot.text, as: snapshot.format))
    }

    /// Changes how the file is saved, with undo. The editor marks the window edited
    /// (see `EditorController.noteChange`).
    @MainActor func setFormat(_ newFormat: TextFormat, undoManager: UndoManager?) {
        let old = format
        guard newFormat != old else { return }
        format = newFormat
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.setFormat(old, undoManager: undoManager) }
        }
        undoManager?.setActionName(newFormat.encoding != old.encoding ? "Change Encoding" : "Change Line Endings")
    }
}
