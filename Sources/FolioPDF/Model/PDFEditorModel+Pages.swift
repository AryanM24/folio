import AppKit
import FolioKit
import PDFKit
import UniformTypeIdentifiers

/// Page operations. Each is undoable by applying its inverse, which registers the
/// original operation again for redo.
extension PDFEditorModel {
    // MARK: Primitives

    /// Inserts `pages` starting at `index`, in order.
    func insert(_ pages: [PDFPage], at index: Int, name: String = "Insert Pages") {
        guard !pages.isEmpty else { return }
        let start = min(max(0, index), pageCount)
        mutate { pdf in
            for (offset, page) in pages.enumerated() { pdf.insert(page, at: start + offset) }
        }
        registerUndo(name) { $0.remove(pages, name: name) }
        selectedPages = Set(start..<(start + pages.count))
        go(toPage: start)
    }

    /// Removes `pages`, remembering where each one was for undo. Refuses to remove
    /// every page: a PDF with no pages can't be saved.
    func remove(_ pages: [PDFPage], name: String = "Delete Pages") {
        let placed = pages.compactMap { page -> (PDFPage, Int)? in
            let index = pdf.index(for: page)
            return index == NSNotFound ? nil : (page, index)
        }
        guard !placed.isEmpty else { return }
        guard placed.count < pageCount else {
            show(FolioError("A PDF needs at least one page. Add a page before deleting this one."), title: "Can't delete every page")
            return
        }
        if let selected = selectedAnnotation?.page, placed.contains(where: { $0.0 == selected }) { select(nil) }
        mutate { pdf in
            for (_, index) in placed.sorted(by: { $0.1 > $1.1 }) { pdf.removePage(at: index) }
        }
        registerUndo(name) { $0.restore(placed, name: name) }
        selectedPages = []
        currentPageIndex = min(currentPageIndex, pageCount - 1)
    }

    /// Puts pages back at their original indices (the inverse of remove and move).
    /// Pages still in the document are taken out first, so this also undoes a move.
    func restore(_ placed: [(PDFPage, Int)], name: String) {
        let current = placed.compactMap { page, _ -> (PDFPage, Int)? in
            let index = pdf.index(for: page)
            return index == NSNotFound ? nil : (page, index)
        }
        mutate { pdf in
            for (_, index) in current.sorted(by: { $0.1 > $1.1 }) { pdf.removePage(at: index) }
            for (page, index) in placed.sorted(by: { $0.1 < $1.1 }) { pdf.insert(page, at: min(index, pdf.pageCount)) }
        }
        if current.isEmpty {
            registerUndo(name) { $0.remove(placed.map(\.0), name: name) }
        } else {
            registerUndo(name) { $0.restore(current, name: name) }
        }
        selectedPages = Set(placed.map(\.1))
        if let first = placed.map(\.1).min() { go(toPage: first) }
    }

    /// Moves `indices` so they start at `destination` (an index in the current order,
    /// before the move), keeping their relative order. Used by sidebar drag and drop.
    func movePages(_ indices: [Int], to destination: Int) {
        let sorted = indices.sorted().filter { $0 < pageCount }
        let pages = sorted.compactMap { pdf.page(at: $0) }
        guard !pages.isEmpty else { return }
        let placed = Array(zip(pages, sorted))
        let target = destination - sorted.filter { $0 < destination }.count
        let contiguous = sorted[sorted.count - 1] - sorted[0] == sorted.count - 1
        guard !(contiguous && target == sorted[0]) else { return }
        mutate { pdf in
            for index in sorted.reversed() { pdf.removePage(at: index) }
            for (offset, page) in pages.enumerated() { pdf.insert(page, at: min(target + offset, pdf.pageCount)) }
        }
        registerUndo("Move Pages") { $0.restore(placed, name: "Move Pages") }
        selectedPages = Set(target..<(target + pages.count))
        go(toPage: target)
    }

    /// Sidebar drop: moves the dragged page, or the whole selection if it was part of
    /// it, before `index`. `items` are the page indices the drag carried.
    func dropPages(_ items: [String], before index: Int) -> Bool {
        guard let from = items.first.flatMap(Int.init) else { return false }
        movePages(selectedPages.contains(from) ? Array(selectedPages) : [from], to: index)
        return true
    }

    /// Swaps pages for rebuilt versions (redaction, OCR, flattening). One undo step.
    func replace(_ replacements: [(old: PDFPage, new: PDFPage)], name: String) {
        let valid = replacements.filter { pdf.index(for: $0.old) != NSNotFound }
        guard !valid.isEmpty else { return }
        if let selected = selectedAnnotation?.page, valid.contains(where: { $0.old == selected }) { select(nil) }
        mutate(touching: valid.map(\.new)) { pdf in
            for pair in valid {
                let index = pdf.index(for: pair.old)
                pdf.removePage(at: index)
                pdf.insert(pair.new, at: index)
            }
        }
        registerUndo(name) { $0.replace(valid.map { (old: $0.new, new: $0.old) }, name: name) }
    }

    // MARK: Commands

    func rotate(_ indices: [Int], by degrees: Int) {
        let pages = indices.compactMap { pdf.page(at: $0) }
        guard !pages.isEmpty else { return }
        mutate(touching: pages) { _ in
            for page in pages { page.rotation = Geometry.normalized(page.rotation + degrees) }
        }
        let name = degrees > 0 ? "Rotate Right" : "Rotate Left"
        registerUndo(name) { model in
            model.rotate(pages.map { model.pdf.index(for: $0) }.filter { $0 != NSNotFound }, by: -degrees)
        }
    }

    func rotateLeft() { rotate(targetPages, by: -90) }
    func rotateRight() { rotate(targetPages, by: 90) }

    /// A blank page the size of the current one, after it.
    func insertBlankPage() {
        let size = currentPage?.bounds(for: .mediaBox) ?? PageFactory.defaultPaper
        guard let page = PageFactory.blankPage(size: CGRect(origin: .zero, size: size.size)) else { return }
        insert([page], at: currentPageIndex + 1, name: "Insert Blank Page")
    }

    func deleteSelectedPages() {
        remove(targetPages.compactMap { pdf.page(at: $0) })
    }

    /// Copies of the target pages, inserted after the last of them.
    func duplicateSelectedPages() {
        let indices = targetPages
        let copies = indices.compactMap { pdf.page(at: $0)?.copy() as? PDFPage }
        guard let last = indices.last else { return }
        insert(copies, at: last + 1, name: "Duplicate Pages")
    }

    /// Asks for PDFs or images and inserts their pages after the current page.
    func insertPagesFromFile() async {
        let urls = await Exporter.pick(types: [.pdf, .image], window: pdfView?.window)
        guard !urls.isEmpty else { return }
        let paper = currentPage?.bounds(for: .mediaBox) ?? PageFactory.defaultPaper
        var pages: [PDFPage] = []
        for url in urls {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                do {
                    let source = try PDFOperations.load(url)
                    pages += (0..<source.pageCount).compactMap { source.page(at: $0) }
                } catch {
                    show(error, title: "Couldn't insert “\(url.lastPathComponent)”")
                }
            } else if let image = PageFactory.image(at: url),
                let page = PageFactory.page(for: image, fitting: PageFactory.paper(paper, orientedFor: image))
            {
                pages.append(page)
            } else {
                show(FolioError("“\(url.lastPathComponent)” couldn't be read as an image."), title: "Couldn't insert pages")
            }
        }
        insert(pages, at: currentPageIndex + 1)
    }

    // MARK: Navigation

    func go(toPage index: Int) {
        guard let page = pdf.page(at: min(max(0, index), pageCount - 1)) else { return }
        pdfView?.go(to: page)
        currentPageIndex = pdf.index(for: page)
    }

    func nextPage() { go(toPage: currentPageIndex + 1) }
    func previousPage() { go(toPage: currentPageIndex - 1) }
}
