import FolioCode
import FolioDocs
import FolioKit
import FolioPDF
import FolioSheets
import Foundation

/// The Folio library: a plain folder (by default ~/Documents/Folio) where new work is
/// saved. Files stay ordinary files the person can see, move and back up; Folio keeps no
/// private database.
///
/// `FOLIO_LIBRARY_DIR` overrides the location, so tests and `scripts/snapshot.sh` never
/// touch the real library. With the override set, the workspace also keeps Recent and
/// Favorites inside that folder, so screenshots never show the developer's own files.
nonisolated enum Library {
    /// UserDefaults key for a library folder chosen in Settings › General.
    static let pathKey = "workspace.libraryPath"

    /// Set in tests and snapshots: keep every list inside the library folder.
    static var isIsolated: Bool { ProcessInfo.processInfo.environment["FOLIO_LIBRARY_DIR"] != nil }

    static var url: URL {
        if let dir = ProcessInfo.processInfo.environment["FOLIO_LIBRARY_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        if let path = UserDefaults.standard.string(forKey: pathKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let documents =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Documents")
        return documents.appending(path: "Folio", directoryHint: .isDirectory)
    }

    /// The library folder, created on first use.
    static func ensureExists() throws -> URL {
        let url = url
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The kinds of new file the "Start something" row creates, each written to disk with
/// its editor's own empty content before it opens, so new work is always saved somewhere.
nonisolated enum NewFile: String, CaseIterable, Identifiable, Sendable {
    case document, spreadsheet, text, markdown, pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .document: "Document"
        case .spreadsheet: "Spreadsheet"
        case .text: "Text & Code"
        case .markdown: "Markdown"
        case .pdf: "PDF"
        }
    }

    /// The format, as shown under the tile.
    var subtitle: String {
        switch self {
        case .document: "Word .docx"
        case .spreadsheet: "Excel .xlsx"
        case .text: "Plain .txt"
        case .markdown: "Notes .md"
        case .pdf: "Blank page"
        }
    }

    /// Finder-style base name; `FolioTool.unique` adds " 2", " 3"… when taken.
    var baseName: String {
        switch self {
        case .document: "Untitled document"
        case .spreadsheet: "Untitled spreadsheet"
        case .text: "Untitled"
        case .markdown: "Untitled notes"
        case .pdf: "Untitled PDF"
        }
    }

    var fileExtension: String {
        switch self {
        case .document: "docx"
        case .spreadsheet: "xlsx"
        case .text: "txt"
        case .markdown: "md"
        case .pdf: "pdf"
        }
    }

    var kind: FileKind {
        switch self {
        case .document: .document
        case .spreadsheet: .spreadsheet
        case .text, .markdown: .code
        case .pdf: .pdf
        }
    }

    /// Valid empty content in this format, from the editor module that owns it.
    func emptyData() throws -> Data {
        switch self {
        case .document: RichTextDocument.emptyFileData()
        case .spreadsheet: try SpreadsheetDocument.emptyFileData()
        case .text, .markdown: Data()
        case .pdf: PDFFileDocument.emptyFileData()
        }
    }

    /// Writes a new, uniquely named file into `folder` and returns its URL.
    func create(in folder: URL) throws -> URL {
        let url = FolioTool.unique(in: folder, name: baseName, ext: fileExtension)
        try emptyData().write(to: url, options: .withoutOverwriting)
        return url
    }
}

/// Favorites are the Finder tag "Folio Favorite", so a starred file shows its star in
/// Finder too and survives being moved, synced or opened by another app.
nonisolated enum Favorites {
    static let tag = "Folio Favorite"

    static func set(_ favorite: Bool, for url: URL) throws {
        var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        tags.removeAll { $0 == tag }
        if favorite { tags.append(tag) }
        // URLResourceValues.tagNames is read-only in Swift; NSURL can write it.
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}

/// Folders the person added under "Locations", kept as bookmarks so they still resolve
/// after being renamed or moved.
enum Locations {
    static let key = "workspace.locations"

    static func load() -> [URL] {
        let bookmarks = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        return bookmarks.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
        }
    }

    static func save(_ urls: [URL]) {
        UserDefaults.standard.set(urls.compactMap { try? $0.bookmarkData() }, forKey: key)
    }
}
