import AppKit
import FolioKit

/// The document laid out on real pages, for Print and PDF export.
///
/// Text flows through one text container per page, each the size of the page minus
/// its margins, so page breaks (form feeds), tables and images paginate exactly as
/// the text system lays them out. The view is as tall as all pages stacked, and
/// tells the print system where each page is, so margins are honoured precisely
/// instead of being approximated by `NSPrintInfo` margins.
final class PaginatedView: NSView {
    private let storage: NSTextStorage
    private let layout = MarkerLayoutManager()
    let page: PageSetup
    private(set) var pageCount = 0

    /// Hard limit so a pathological document (an image taller than a page that can
    /// never fit) can't add containers forever.
    private static let maxPages = 20_000

    init(text: NSAttributedString, page: PageSetup) {
        storage = NSTextStorage(attributedString: text)
        self.page = page
        super.init(frame: .zero)
        storage.addLayoutManager(layout)
        layout.allowsNonContiguousLayout = false
        while pageCount < Self.maxPages {
            let container = NSTextContainer(size: page.contentSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            pageCount += 1
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) >= layout.numberOfGlyphs || (range.length == 0 && pageCount > 1) { break }
        }
        frame = NSRect(x: 0, y: 0, width: page.paperSize.width, height: page.paperSize.height * CGFloat(pageCount))
        appearance = NSAppearance(named: .aqua)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used from Interface Builder") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        for (index, container) in layout.textContainers.enumerated() {
            let pageRect = rectForPage(index + 1)
            guard pageRect.intersects(dirtyRect) else { continue }
            let range = layout.glyphRange(for: container)
            let origin = NSPoint(x: page.margins.left, y: pageRect.minY + page.margins.top)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
        }
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    override func rectForPage(_ number: Int) -> NSRect {
        NSRect(x: 0, y: page.paperSize.height * CGFloat(number - 1), width: page.paperSize.width, height: page.paperSize.height)
    }

    /// Print settings matching the page: its paper, no extra margins (the view draws
    /// them), no scaling.
    func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = page.paperSize
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.scalingFactor = 1
        return info
    }
}

/// Paginated PDF output through the print system (`NSPrintOperation`), so the PDF
/// matches what Print produces, with the document's own paper and margins.
enum PDFRenderer {
    static func pdf(_ text: NSAttributedString, page: PageSetup) throws -> Data {
        let view = PaginatedView(text: text, page: page)
        // `pdfOperation(with:inside:to:)` renders one tall page; a print job saved to
        // a file uses the view's pagination (`knowsPageRange`/`rectForPage`).
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = view.printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw FolioError("Folio couldn't create the PDF.")
        }
        return data
    }
}
