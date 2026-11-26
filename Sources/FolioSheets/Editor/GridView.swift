import AppKit
import FolioKit

/// The virtualized, custom-drawn spreadsheet grid. It is the document view of an
/// `NSScrollView`; only the cells intersecting the dirty rect are drawn, so a
/// 100k-row sheet costs the same to draw as a 10-row one.
///
/// The column letters, row numbers and frozen panes are three small "pane" subviews
/// pinned to the visible rect on every scroll (sticky headers). They are not
/// hit-testable, so every click lands here and is classified by position.
final class GridView: NSView {
    weak var controller: SheetController?
    private(set) var layout: GridLayout
    let topPane = GridPane(.top)
    let leftPane = GridPane(.left)
    let cornerPane = GridPane(.corner)
    let editor = CellEditorField()

    /// Column being resized and its live width.
    var resizing: (col: Int, width: Double)?
    /// Attribute dictionaries per style, so drawing doesn't rebuild fonts per cell.
    var attributeCache: [CellStyle: [NSAttributedString.Key: Any]] = [:]
    var editingCell: CellRef?
    /// Guards against re-entering autocomplete while it inserts a completion.
    var isCompleting = false

    init(controller: SheetController) {
        self.controller = controller
        layout = GridLayout(sheet: controller.sheet, rows: controller.displayRows, cols: controller.displayCols)
        super.init(frame: CGRect(origin: .zero, size: layout.contentSize))
        for pane in [topPane, leftPane, cornerPane] {
            pane.grid = self
            addSubview(pane)
        }
        editor.isHidden = true
        editor.cellDelegate = self
        addSubview(editor)
        setAccessibilityRole(.table)
        setAccessibilityLabel("Spreadsheet")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GridView is created in code") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    /// Sticky panes must move in lockstep with scrolling.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self)
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: clip)
        // Window resizes change the visible rect without scrolling.
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.frameDidChangeNotification, object: clip)
        layoutPanes()
    }

    @objc private func didScroll() {
        layoutPanes()
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        attributeCache.removeAll()
        needsDisplay = true
        for p in [topPane, leftPane, cornerPane] { p.needsDisplay = true }
    }

    // MARK: - Reloading

    /// Rebuilds geometry after any document change, then redraws.
    func reloadLayout() {
        guard let c = controller else { return }
        layout = GridLayout(sheet: c.sheet, rows: c.displayRows, cols: c.displayCols, widthOverride: resizing)
        let size = layout.contentSize
        if frame.size != size { setFrameSize(size) }
        layoutPanes()
        needsDisplay = true
        if let cell = editingCell { positionEditor(at: cell) }
    }

    func selectionDidChange() {
        guard let c = controller else { return }
        // The grid grows as the selection approaches its edge.
        if c.displayRows != layout.rows || c.displayCols != layout.cols { reloadLayout() }
        needsDisplay = true
        for p in [topPane, leftPane, cornerPane] { p.needsDisplay = true }
        // Clicking a row or column header shouldn't scroll the sheet sideways.
        if c.selection.kind == .cells { scrollToReveal(c.selection.cursor) }
        announceSelection()
    }

    /// Positions the sticky panes over the visible rect.
    func layoutPanes() {
        let v = visibleRect
        let l = layout
        topPane.frame = CGRect(x: v.minX + l.leftBand, y: v.minY, width: max(0, v.width - l.leftBand), height: l.topBand)
        leftPane.frame = CGRect(x: v.minX, y: v.minY + l.topBand, width: l.leftBand, height: max(0, v.height - l.topBand))
        cornerPane.frame = CGRect(x: v.minX, y: v.minY, width: l.leftBand, height: l.topBand)
        for p in [topPane, leftPane, cornerPane] { p.needsDisplay = true }
    }

    var visibleRowCount: Int { Int((visibleRect.height - layout.topBand) / GridLayout.rowHeight) }

    /// Scrolls so a cell is fully visible below and right of the sticky bands.
    func scrollToReveal(_ cell: CellRef) {
        guard let clip = superview as? NSClipView else { return }
        let v = visibleRect, l = layout
        let r = l.rect(of: cell)
        var origin = clip.bounds.origin
        if cell.col >= l.frozenCols {
            if r.minX < v.minX + l.leftBand {
                origin.x = r.minX - l.leftBand
            } else if r.maxX > v.maxX {
                origin.x = min(r.minX - l.leftBand, r.maxX - v.width)
            }
        }
        if cell.row >= l.frozenRows {
            if r.minY < v.minY + l.topBand { origin.y = r.minY - l.topBand } else if r.maxY > v.maxY { origin.y = r.maxY - v.height }
        }
        origin.x = max(0, origin.x)
        origin.y = max(0, origin.y)
        if origin != clip.bounds.origin {
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    func focus() { window?.makeFirstResponder(self) }

    // MARK: - Hit testing

    enum Hit: Equatable {
        case corner
        case columnHeader(Int, border: Int?)
        case rowHeader(Int)
        case cell(CellRef)
    }

    /// Maps a point in view coordinates to "natural" grid coordinates, undoing the sticky offset.
    func natural(_ p: CGPoint) -> CGPoint {
        let v = visibleRect, l = layout
        return CGPoint(
            x: p.x < v.minX + l.leftBand ? p.x - v.minX : p.x,
            y: p.y < v.minY + l.topBand ? p.y - v.minY : p.y)
    }

    func hit(_ p: CGPoint) -> Hit {
        let n = natural(p)
        let l = layout
        let inHeader = n.y < GridLayout.columnHeaderHeight
        let inRowHeader = n.x < l.rowHeaderWidth
        if inHeader && inRowHeader { return .corner }
        if inHeader { return .columnHeader(l.column(atX: n.x), border: l.columnBorder(nearX: n.x)) }
        if inRowHeader { return .rowHeader(l.row(atY: n.y)) }
        return .cell(CellRef(row: l.row(atY: n.y), col: l.column(atX: n.x)))
    }

    /// Where a cell appears on screen (in view coordinates), accounting for sticky panes.
    func displayedRect(of cell: CellRef) -> CGRect {
        var r = layout.rect(of: cell)
        let v = visibleRect
        if cell.col < layout.frozenCols { r.origin.x += v.minX }
        if cell.row < layout.frozenRows { r.origin.y += v.minY }
        return r
    }

    override func resetCursorRects() {
        let v = visibleRect, l = layout
        for c in l.cols(in: v) {
            let x = l.x(ofColumn: c + 1)
            addCursorRect(CGRect(x: x - 3, y: v.minY, width: 6, height: GridLayout.columnHeaderHeight), cursor: .resizeLeftRight)
        }
        for c in 0..<l.frozenCols {
            let x = l.x(ofColumn: c + 1) + v.minX
            addCursorRect(CGRect(x: x - 3, y: v.minY, width: 6, height: GridLayout.columnHeaderHeight), cursor: .resizeLeftRight)
        }
    }

    // MARK: - Accessibility

    private func announceSelection() {
        guard let c = controller else { return }
        let cell = c.selection.active
        let text = c.document.displayText(at: cell)
        let description = "\(cell.a1), \(text.isEmpty ? "empty" : text)"
        setAccessibilityValue(description)
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [
                .announcement: description, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }
}
