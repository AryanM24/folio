import AppKit
import FolioKit
import PDFKit

/// Whole-document operations shared by the editor and the tools.
///
/// These are plain functions over `PDFDocument` with no UI and no undo, so they can be
/// unit-tested and run off the main actor. The editor wraps the ones that change an
/// open document in undoable model methods (see `PDFEditorModel+Pages.swift`).
nonisolated enum PDFOperations {
    // MARK: Reading and writing

    /// Opens a PDF for a tool, with an error a person can act on.
    static func load(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw FolioError("“\(url.lastPathComponent)” isn't a PDF, or it's damaged.")
        }
        guard !document.isLocked else {
            throw FolioError("“\(url.lastPathComponent)” is protected with a password.")
        }
        return document
    }

    /// Serialises `document`. `options` are PDFKit write options.
    static func data(_ document: PDFDocument, options: [PDFDocumentWriteOption: Any] = [:]) throws -> Data {
        let data = options.isEmpty ? document.dataRepresentation() : document.dataRepresentation(options: options)
        guard let data else { throw FolioError("Folio couldn't write the PDF.") }
        return data
    }

    /// Every annotation (form values, ink, stamps, notes) burned into the page content,
    /// so it prints and displays the same everywhere and can no longer be edited.
    static func flattenedData(_ document: PDFDocument) throws -> Data {
        try data(document, options: [.burnInAnnotationsOption: true])
    }

    /// Smaller output: images downsampled and recompressed. See ``Compressor``.
    static func compressedData(_ document: PDFDocument) throws -> Data {
        try Compressor.compressed(document)
    }

    // MARK: Building documents

    /// Independent copies of the pages at `indices`, content and annotations included.
    ///
    /// `PDFPage.copy()` can't be trusted for this: on some macOS versions (seen on 26.x)
    /// the copy has no content stream, so a duplicated or extracted page comes out blank.
    /// Instead, serialize the document once and take the pages from a fresh parse. Those
    /// pages belong to no live document, so they can be inserted anywhere. Out-of-range
    /// indices are skipped.
    static func copies(of indices: [Int], from document: PDFDocument) -> [PDFPage] {
        guard !indices.isEmpty, let data = document.dataRepresentation(), let fresh = PDFDocument(data: data) else { return [] }
        let pages = indices.compactMap { fresh.page(at: $0) }
        // Detach from `fresh` so the pages can join another document.
        for page in pages.reversed() {
            let index = fresh.index(for: page)
            if index != NSNotFound { fresh.removePage(at: index) }
        }
        return pages
    }

    /// A new document made of copies of `indices` (in order), with annotations.
    static func extract(_ indices: [Int], from document: PDFDocument) -> PDFDocument {
        let result = PDFDocument()
        for page in copies(of: indices, from: document) {
            result.insert(page, at: result.pageCount)
        }
        result.documentAttributes = document.documentAttributes
        return result
    }

    /// All pages of `documents`, in order, in one new document.
    static func combine(_ documents: [PDFDocument]) -> PDFDocument {
        let result = PDFDocument()
        for document in documents {
            for page in copies(of: Array(0..<document.pageCount), from: document) {
                result.insert(page, at: result.pageCount)
            }
        }
        return result
    }

    /// One document per page.
    static func split(_ document: PDFDocument) -> [PDFDocument] {
        (0..<document.pageCount).map { extract([$0], from: document) }
    }

    /// A document with one page per image, each fitted to the user's paper size in the
    /// image's orientation (a 4000 px photo at 72 dpi would be a 55-inch page).
    static func document(fromImages images: [CGImage]) -> PDFDocument {
        let result = PDFDocument()
        for image in images {
            let paper = PageFactory.paper(PageFactory.defaultPaper, orientedFor: image)
            guard let page = PageFactory.page(for: image, fitting: paper) else { continue }
            result.insert(page, at: result.pageCount)
        }
        return result
    }

    // MARK: Changing documents in place

    /// Turns every page by `degrees` (a multiple of 90; positive is clockwise).
    static func rotateAll(_ document: PDFDocument, by degrees: Int) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.rotation = Geometry.normalized(page.rotation + degrees)
        }
    }

    /// Replaces each page with `transform(page, index)`, keeping the original when the
    /// transform returns `nil`. Returns the originals, for undo.
    @discardableResult
    static func replacePages(_ document: PDFDocument, with transform: (PDFPage, Int) -> PDFPage?) -> [PDFPage] {
        var originals: [PDFPage] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            originals.append(page)
            guard let replacement = transform(page, index) else { continue }
            document.removePage(at: index)
            document.insert(replacement, at: index)
        }
        return originals
    }

    /// Prints "n of N" at the bottom of every page.
    static func addPageNumbers(_ document: PDFDocument) {
        let count = document.pageCount
        replacePages(document) { page, index in
            PageStamper.numbered(page, label: PageStamper.pageLabel(index: index, count: count))
        }
    }

    /// Prints `text` diagonally across every page.
    static func addWatermark(_ document: PDFDocument, text: String) {
        replacePages(document) { page, _ in PageStamper.watermarked(page, text: text) }
    }

    // MARK: Reading content

    /// All text, pages separated by a form feed so the page breaks survive in plain text.
    static func text(of document: PDFDocument) -> String {
        (0..<document.pageCount)
            .map { document.page(at: $0)?.string ?? "" }
            .joined(separator: "\n\u{0C}\n")
    }
}
