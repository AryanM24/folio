import AppKit

/// A sticky band of the grid: column letters plus frozen rows (`top`), row numbers plus
/// frozen columns (`left`), or their intersection (`corner`). Draws by asking the grid
/// to paint its content in grid coordinates.
final class GridPane: NSView {
    enum Kind { case top, left, corner }
    let kind: Kind
    weak var grid: GridView?

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GridPane is created in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// Clicks fall through to the grid, which classifies them by position.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Translate so the grid draws in its "natural" coordinates: the axis this pane
        // scrolls along keeps document coordinates, the pinned axis starts at zero.
        let dx = kind == .top ? -frame.minX : 0
        let dy = kind == .left ? -frame.minY : 0
        ctx.saveGState()
        ctx.translateBy(x: dx, y: dy)
        grid.drawPane(kind, region: frame.offsetBy(dx: kind == .top ? 0 : -frame.minX, dy: kind == .left ? 0 : -frame.minY))
        ctx.restoreGState()
    }
}

extension GridView {
    override func draw(_ dirtyRect: NSRect) {
        GridPalette.surface.setFill()
        dirtyRect.fill()
        let l = layout
        drawCells(rows: l.rows(in: dirtyRect), cols: l.cols(in: dirtyRect))
        drawSelection()
    }

    /// Paints one sticky pane. `region` is the pane's area in natural coordinates.
    func drawPane(_ kind: GridPane.Kind, region: CGRect) {
        let l = layout
        GridPalette.surface.setFill()
        region.fill()
        let frozenRows = 0..<l.frozenRows, frozenCols = 0..<l.frozenCols
        switch kind {
        case .top:
            let cols = l.cols(in: region)
            drawCells(rows: frozenRows, cols: cols)
            drawSelection()
            drawColumnHeaders(cols)
            if l.frozenRows > 0 { drawFrozenDivider(horizontal: true, at: l.topBand, from: region.minX, to: region.maxX) }
        case .left:
            let rows = l.rows(in: region)
            drawCells(rows: rows, cols: frozenCols)
            drawSelection()
            drawRowHeaders(rows)
            if l.frozenCols > 0 { drawFrozenDivider(horizontal: false, at: l.leftBand, from: region.minY, to: region.maxY) }
        case .corner:
            drawCells(rows: frozenRows, cols: frozenCols)
            drawSelection()
            drawColumnHeaders(frozenCols)
            drawRowHeaders(frozenRows)
            drawCornerBox()
            if l.frozenRows > 0 { drawFrozenDivider(horizontal: true, at: l.topBand, from: 0, to: l.leftBand) }
            if l.frozenCols > 0 { drawFrozenDivider(horizontal: false, at: l.leftBand, from: 0, to: l.topBand) }
        }
    }

    // MARK: - Cells

    func drawCells(rows: Range<Int>, cols: Range<Int>) {
        guard let c = controller, !rows.isEmpty, !cols.isEmpty else { return }
        let l = layout
        let sheet = c.sheet
        let doc = c.document

        // Backgrounds first, so text that spills into a neighbour isn't painted over.
        // The selection tint is pre-blended into opaque colours rather than drawn as a
        // translucent overlay, so repeated partial redraws can't darken it.
        let selection = c.selectedRange
        let active = c.selection.active
        let tinted = !selection.isSingleCell
        let accent = GridPalette.accent
        if tinted,
            let visible = selection.intersection(
                CellRange(
                    CellRef(row: rows.lowerBound, col: cols.lowerBound),
                    CellRef(row: rows.upperBound - 1, col: cols.upperBound - 1)))
        {
            GridPalette.surface.blended(with: accent, fraction: 0.14).setFill()
            l.rect(of: visible).fill()
            if visible.contains(active) {
                GridPalette.surface.setFill()
                l.rect(of: active).fill()
            }
        }
        for (ref, style) in stylesWithFill(sheet, rows: rows, cols: cols) {
            if let f = style.fill {
                let color = NSColor(srgbRed: f.red, green: f.green, blue: f.blue, alpha: 1)
                let selected = tinted && selection.contains(ref) && ref != active
                (selected ? color.blended(with: accent, fraction: 0.2) : color).setFill()
                l.rect(of: ref).fill()
            }
        }

        // Grid lines.
        GridPalette.separator.setFill()
        let top = l.y(ofRow: rows.lowerBound), bottom = l.y(ofRow: rows.upperBound)
        let left = l.x(ofColumn: cols.lowerBound), right = l.x(ofColumn: cols.upperBound)
        for col in cols { CGRect(x: l.x(ofColumn: col + 1) - 1, y: top, width: 1, height: bottom - top).fill() }
        for row in rows { CGRect(x: left, y: l.y(ofRow: row + 1) - 1, width: right - left, height: 1).fill() }

        // Text.
        for row in rows {
            var col = cols.lowerBound
            while col < cols.upperBound {
                let ref = CellRef(row: row, col: col)
                defer { col += 1 }
                guard sheet.cells[ref] != nil, ref != editingCell else { continue }
                let style = sheet.style(at: ref)
                let value = doc.value(at: ref)
                let text = ValueFormatter.shared.string(for: value, format: style.numberFormat)
                guard !text.isEmpty else { continue }
                var rect = l.rect(of: ref).insetBy(dx: 6, dy: 0)
                let align = alignment(style.alignment, for: value)
                // Left-aligned text spills into empty neighbours, as in every spreadsheet.
                if align == .left, !value.isNumber {
                    var next = col + 1
                    while next < cols.upperBound + 8, next < l.cols, sheet.cells[CellRef(row: row, col: next)] == nil,
                        sheet.style(at: CellRef(row: row, col: next)).fill == nil,
                        textWidth(text, style) > rect.width
                    {
                        rect.size.width += l.width(ofColumn: next)
                        next += 1
                    }
                }
                drawText(text, in: rect, style: style, alignment: align, isError: value.errorValue != nil)
            }
        }
    }

    /// Styled cells with a fill in the region, without scanning every visible cell
    /// when the sheet has few styles.
    private func stylesWithFill(_ sheet: Sheet, rows: Range<Int>, cols: Range<Int>) -> [(CellRef, CellStyle)] {
        if sheet.styles.count < rows.count * cols.count {
            return sheet.styles.filter { ref, s in s.fill != nil && rows.contains(ref.row) && cols.contains(ref.col) }.map {
                ($0.key, $0.value)
            }
        }
        var out: [(CellRef, CellStyle)] = []
        for r in rows {
            for c in cols { if let s = sheet.styles[CellRef(row: r, col: c)], s.fill != nil { out.append((CellRef(row: r, col: c), s)) } }
        }
        return out
    }

    private func alignment(_ a: HorizontalAlignment, for value: CellValue) -> NSTextAlignment {
        switch a {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .automatic:
            switch value {
            case .number: return .right
            case .bool, .error: return .center
            default: return .left
            }
        }
    }

    func attributes(for style: CellStyle) -> [NSAttributedString.Key: Any] {
        var key = style
        key.alignment = .automatic
        key.fill = nil
        key.numberFormat = .general
        if let cached = attributeCache[key] { return cached }
        var font = NSFont.systemFont(ofSize: 13)
        if style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if let t = style.textColor {
            attrs[.foregroundColor] = NSColor(srgbRed: t.red, green: t.green, blue: t.blue, alpha: 1)
        } else {
            attrs[.foregroundColor] = GridPalette.text
        }
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributeCache[key] = attrs
        return attrs
    }

    private func textWidth(_ text: String, _ style: CellStyle) -> CGFloat {
        (text as NSString).size(withAttributes: attributes(for: style)).width
    }

    private func drawText(_ text: String, in rect: CGRect, style: CellStyle, alignment: NSTextAlignment, isError: Bool) {
        var attrs = attributes(for: style)
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byClipping
        attrs[.paragraphStyle] = para
        if isError && style.textColor == nil {
            attrs[.foregroundColor] = GridPalette.danger
        } else if style.textColor == nil, let fill = style.fill {
            // Fills are fixed colours, so pick ink that reads on them in light and dark mode.
            attrs[.foregroundColor] = fill.isLight ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.98, alpha: 1)
        }
        // Single line, vertically centred; newlines show as spaces like Numbers' collapsed rows.
        let line = text.contains("\n") ? text.replacingOccurrences(of: "\n", with: " ") : text
        let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 13)
        let h = ceil(font.ascender - font.descender)
        let r = CGRect(x: rect.minX, y: rect.minY + (rect.height - h) / 2, width: rect.width, height: h + 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        (line as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Selection

    /// The 2 pt accent border around the selection (the soft fill is drawn with the cell backgrounds).
    func drawSelection() {
        guard let c = controller else { return }
        let l = layout
        let range = c.selectedRange
        let visibleRange = CellRange(range.start, CellRef(row: min(range.end.row, l.rows - 1), col: min(range.end.col, l.cols - 1)))
        var outer = l.rect(of: visibleRange)
        if editingCell == c.selection.active, range.isSingleCell, !editor.isHidden {
            outer.size.width = max(outer.width, editor.frame.width + 8)
        }
        GridPalette.accent.setStroke()
        // Centred on the grid lines, which sit on the last pixel of each cell.
        let border = NSBezierPath(rect: outer.offsetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 2
        border.stroke()
    }

    // MARK: - Headers

    private func headerFont(selected: Bool) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        return [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: selected ? .semibold : .regular),
            .foregroundColor: selected ? GridPalette.headerTextSelected : GridPalette.headerText,
            .paragraphStyle: para,
        ]
    }

    private func headerSelection() -> (rows: ClosedRange<Int>, cols: ClosedRange<Int>, fullRows: Bool, fullCols: Bool) {
        guard let c = controller else { return (0...0, 0...0, false, false) }
        let r = c.selectedRange
        return (r.rows, r.cols, c.selection.kind == .rows, c.selection.kind == .columns)
    }

    func drawColumnHeaders(_ cols: Range<Int>) {
        let l = layout
        let sel = headerSelection()
        let h = GridLayout.columnHeaderHeight
        for col in cols {
            let x = l.x(ofColumn: col), w = l.width(ofColumn: col)
            let rect = CGRect(x: x, y: 0, width: w, height: h)
            let selected = sel.cols.contains(col)
            (selected ? (sel.fullCols ? GridPalette.accent.withAlphaComponent(0.22) : GridPalette.headerSelected) : GridPalette.header)
                .setFill()
            rect.fill()
            GridPalette.separator.setFill()
            CGRect(x: rect.maxX - 1, y: 4, width: 1, height: h - 8).fill()
            let name = CellRef.columnName(col) as NSString
            name.draw(
                with: CGRect(x: x, y: (h - 14) / 2, width: w, height: 16), options: [.usesLineFragmentOrigin],
                attributes: headerFont(selected: selected))
        }
        GridPalette.border.setFill()
        if let first = cols.first, let last = cols.last {
            CGRect(x: l.x(ofColumn: first), y: h - 1, width: l.x(ofColumn: last + 1) - l.x(ofColumn: first), height: 1).fill()
        }
    }

    func drawRowHeaders(_ rows: Range<Int>) {
        let l = layout
        let sel = headerSelection()
        let w = l.rowHeaderWidth
        for row in rows {
            let y = l.y(ofRow: row)
            let rect = CGRect(x: 0, y: y, width: w, height: GridLayout.rowHeight)
            let selected = sel.rows.contains(row)
            (selected ? (sel.fullRows ? GridPalette.accent.withAlphaComponent(0.22) : GridPalette.headerSelected) : GridPalette.header)
                .setFill()
            rect.fill()
            GridPalette.separator.setFill()
            CGRect(x: 4, y: rect.maxY - 1, width: w - 8, height: 1).fill()
            (String(row + 1) as NSString).draw(
                with: CGRect(x: 0, y: y + (GridLayout.rowHeight - 14) / 2, width: w, height: 16),
                options: [.usesLineFragmentOrigin], attributes: headerFont(selected: selected))
        }
        GridPalette.border.setFill()
        if let first = rows.first, let last = rows.last {
            CGRect(x: w - 1, y: l.y(ofRow: first), width: 1, height: l.y(ofRow: last + 1) - l.y(ofRow: first)).fill()
        }
    }

    private func drawCornerBox() {
        let l = layout
        let rect = CGRect(x: 0, y: 0, width: l.rowHeaderWidth, height: GridLayout.columnHeaderHeight)
        GridPalette.header.setFill()
        rect.fill()
        GridPalette.border.setFill()
        CGRect(x: rect.maxX - 1, y: 0, width: 1, height: rect.height).fill()
        CGRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        // A small triangle hints "select all", like Numbers and Excel.
        let t = NSBezierPath()
        t.move(to: CGPoint(x: rect.maxX - 6, y: rect.maxY - 13))
        t.line(to: CGPoint(x: rect.maxX - 6, y: rect.maxY - 6))
        t.line(to: CGPoint(x: rect.maxX - 13, y: rect.maxY - 6))
        t.close()
        GridPalette.border.setFill()
        t.fill()
    }

    private func drawFrozenDivider(horizontal: Bool, at offset: CGFloat, from a: CGFloat, to b: CGFloat) {
        GridPalette.border.setFill()
        if horizontal {
            CGRect(x: a, y: offset - 2, width: b - a, height: 2).fill()
        } else {
            CGRect(x: offset - 2, y: a, width: 2, height: b - a).fill()
        }
    }
}

extension NSColor {
    /// Opaque mix of two colours, resolved for the current appearance.
    func blended(with other: NSColor, fraction: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        let f = fraction
        return NSColor(
            srgbRed: a.redComponent * (1 - f) + b.redComponent * f,
            green: a.greenComponent * (1 - f) + b.greenComponent * f,
            blue: a.blueComponent * (1 - f) + b.blueComponent * f, alpha: 1)
    }
}
