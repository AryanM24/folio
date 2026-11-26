import AppKit
import FolioKit
import PDFKit

/// `PDFView` plus Folio's annotation tools.
///
/// PDFKit keeps doing what it does well: rendering, scrolling, zooming, text selection,
/// copy, links and form filling. This subclass only intercepts the mouse when a drawing
/// tool is active or an annotation is under the pointer, turns gestures into calls on
/// ``PDFEditorModel`` (which owns undo), and draws live feedback in a non-interactive
/// ``CanvasOverlay`` on top.
final class FolioPDFView: PDFView {
    weak var model: PDFEditorModel?
    private let overlay = CanvasOverlay()
    private var gesture: Gesture?

    /// What the current mouse drag is doing. Coordinates are page space.
    enum Gesture {
        case ink(PDFPage, [CGPoint])
        case rect(PDFPage, start: CGPoint, end: CGPoint)
        case move(PDFAnnotation, start: CGPoint, original: CGRect)
        case resize(PDFAnnotation, Handle, start: CGPoint, original: CGRect)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoScales = true
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        backgroundColor = NSColor(Hero.backgroundSecondary)
        overlay.host = self
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDisplayModeChanged] {
            center.addObserver(self, selector: #selector(viewGeometryChanged), name: name, object: self)
        }
        center.addObserver(self, selector: #selector(textEditingEnded), name: NSText.didEndEditingNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Overlay

    override func layout() {
        super.layout()
        overlay.frame = bounds
        // PDFView re-adds its scroll view on some changes; keep the overlay on top.
        if subviews.last !== overlay { addSubview(overlay, positioned: .above, relativeTo: nil) }
        observeScrolling()
    }

    private var observingScroll = false
    private func observeScrolling() {
        guard !observingScroll, let scroll = documentView?.enclosingScrollView else { return }
        let clip = scroll.contentView
        observingScroll = true
        // Room to scroll the last page clear of the floating tool pill.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets.bottom = 72
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewGeometryChanged), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func viewGeometryChanged() {
        overlay.needsDisplay = true
        model?.viewDidScroll()
    }

    func refreshOverlay() { overlay.needsDisplay = true }

    /// The live gesture and selection, for the overlay to draw.
    var liveGesture: Gesture? { gesture }
    var liveTool: AnnotationTool { model?.tool ?? .select }
    var selection: PDFAnnotation? { model?.selectedAnnotation }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model, let window else { return super.mouseDown(with: event) }
        window.makeFirstResponder(self)
        model.commitFormEdit()
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return super.mouseDown(with: event) }
        let point = convert(viewPoint, to: page)

        switch model.tool {
        case .select:
            selectMouseDown(event, page: page, point: point, viewPoint: viewPoint)
        case .highlight, .underline, .strikeOut:
            super.mouseDown(with: event)
            applyMarkupIfFinished()
        case .note:
            model.addNote(at: point, on: page)
        case .pen, .highlighter:
            gesture = .ink(page, [point])
        case .textBox, .rectangle, .ellipse, .line, .arrow, .redact:
            gesture = .rect(page, start: point, end: point)
        }
        refreshOverlay()
    }

    private func selectMouseDown(_ event: NSEvent, page: PDFPage, point: CGPoint, viewPoint: CGPoint) {
        guard let model else { return }
        if let selected = model.selectedAnnotation, let handle = handle(at: viewPoint, for: selected) {
            gesture = .resize(selected, handle, start: point, original: selected.bounds)
            return
        }
        let hit = page.annotation(at: point)
        if let hit, AnnotationKind(hit).isEditable {
            model.select(hit)
            if AnnotationKind(hit).isMovable { gesture = .move(hit, start: point, original: hit.bounds) }
            if event.clickCount == 2, AnnotationKind(hit).hasText { model.focusTextRequest += 1 }
            return
        }
        model.select(nil)
        if let hit, hit.type == PDFAnnotationSubtype.widget.name { model.beginFormEdit(hit) }
        super.mouseDown(with: event)
        // A click on a checkbox changes it inside super; record it now.
        if hit?.widgetFieldType == .button { model.commitFormEdit() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture, let model else { return super.mouseDragged(with: event) }
        autoscroll(with: event)
        let viewPoint = convert(event.locationInWindow, from: nil)
        switch gesture {
        case .ink(let page, var points):
            points.append(convert(viewPoint, to: page))
            self.gesture = .ink(page, points)
        case .rect(let page, let start, _):
            self.gesture = .rect(page, start: start, end: convert(viewPoint, to: page))
        case .move(let annotation, let start, let original):
            guard let page = annotation.page else { return }
            let point = convert(viewPoint, to: page)
            model.setBoundsLive(annotation, to: original.offsetBy(dx: point.x - start.x, dy: point.y - start.y))
        case .resize(let annotation, let handle, let start, let original):
            guard let page = annotation.page else { return }
            let point = convert(viewPoint, to: page)
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            let rect = handle.resize(original, by: delta, keepAspect: AnnotationKind(annotation).keepsAspect)
            model.setBoundsLive(annotation, to: rect)
        }
        refreshOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return super.mouseUp(with: event) }
        defer {
            gesture = nil
            refreshOverlay()
        }
        switch gesture {
        case .ink(let page, let points):
            model.addInk(points, on: page)
        case .rect(let page, let start, let end):
            model.finishDrag(from: start, to: end, on: page)
        case .move(let annotation, _, let original), .resize(let annotation, _, _, let original):
            model.setBounds(annotation, to: annotation.bounds, from: original)
        case nil:
            super.mouseUp(with: event)
            if model.tool.isMarkup { applyMarkupIfFinished() }
        }
    }

    /// Markup tools act on the text selection once the drag that made it ends.
    /// PDFView may track the drag inside `mouseDown`, so this runs from both ends.
    private func applyMarkupIfFinished() {
        guard let model, model.tool.isMarkup, NSEvent.pressedMouseButtons == 0,
            let selection = currentSelection, !(selection.string ?? "").isEmpty
        else { return }
        model.applyMarkup(model.tool, to: selection)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if model?.tool.draws == true { NSCursor.crosshair.set() }
    }

    // MARK: Keyboard and menu actions

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let selected = model.selectedAnnotation != nil
        // Key codes: 51 delete, 117 forward delete, 53 escape, 123–126 arrows.
        switch event.keyCode {
        case 51 where selected, 117 where selected: model.deleteSelectedAnnotation()
        case 53 where selected: model.select(nil)
        case 53 where model.tool != .select: model.tool = .select
        case 123 where selected: model.nudgeSelection(dx: -step, dy: 0)
        case 124 where selected: model.nudgeSelection(dx: step, dy: 0)
        case 125 where selected: model.nudgeSelection(dx: 0, dy: -step)
        case 126 where selected: model.nudgeSelection(dx: 0, dy: step)
        default: super.keyDown(with: event)
        }
    }

    /// Edit › Delete removes the selected annotation.
    @objc func delete(_ sender: Any?) { model?.deleteSelectedAnnotation() }

    /// File › Print (⌘P) prints the PDF itself, not a picture of the window.
    @objc func printDocument(_ sender: Any?) { model?.printDocument() }
    override func printView(_ sender: Any?) { model?.printDocument() }

    /// Edit › Find routes here when the canvas has focus. The menu items' tags are the
    /// same for both actions: 1 show, 2 next, 3 previous.
    override func performTextFinderAction(_ sender: Any?) { performFindPanelAction(sender) }

    @objc func performFindPanelAction(_ sender: Any?) {
        switch (sender as? NSMenuItem)?.tag {
        case Int(NSFindPanelAction.next.rawValue): model?.findNext()
        case Int(NSFindPanelAction.previous.rawValue): model?.findPrevious()
        default: model?.showFind()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        guard let model else { return base }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let page = page(for: viewPoint, nearest: false),
            let hit = page.annotation(at: convert(viewPoint, to: page)), AnnotationKind(hit).isEditable
        {
            model.select(hit)
            let menu = NSMenu()
            menu.addItem(withTitle: "Delete \(AnnotationKind(hit).title)", action: #selector(delete(_:)), keyEquivalent: "")
            return menu
        }
        return base
    }

    @objc private func textEditingEnded(_ note: Notification) {
        guard let view = note.object as? NSView, view.isDescendant(of: self) else { return }
        model?.commitFormEdit()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { model?.commitFormEdit() }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Geometry helpers

    /// The selection handle under `viewPoint`, if the selection can be resized.
    private func handle(at viewPoint: CGPoint, for annotation: PDFAnnotation) -> Handle? {
        guard AnnotationKind(annotation).isResizable, let page = annotation.page else { return nil }
        let rect = convert(annotation.bounds, from: page)
        return Handle.allCases.first { $0.point(in: rect).distance(to: viewPoint) <= 7 }
    }

    /// The page and page-space point at the middle of what's on screen.
    func visibleCenter() -> (PDFPage, CGPoint)? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let page = page(for: center, nearest: true) else { return nil }
        let crop = page.bounds(for: .cropBox)
        var point = convert(center, to: page)
        point.x = min(max(point.x, crop.minX + 40), crop.maxX - 40)
        point.y = min(max(point.y, crop.minY + 40), crop.maxY - 40)
        return (page, point)
    }
}

/// The eight resize handles around a selected annotation.
enum Handle: CaseIterable {
    case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left

    /// Where the handle sits on `rect` (any coordinate space).
    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.maxY)
        case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private var movesLeft: Bool { [.bottomLeft, .topLeft, .left].contains(self) }
    private var movesRight: Bool { [.bottomRight, .topRight, .right].contains(self) }
    private var movesBottom: Bool { [.bottomLeft, .bottomRight, .bottom].contains(self) }
    private var movesTop: Bool { [.topLeft, .topRight, .top].contains(self) }
    private var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    /// `rect` (page space, y up) with this handle dragged by `delta`. Never smaller
    /// than 8 pt; corner drags keep the aspect ratio when asked, anchored on the
    /// opposite corner.
    func resize(_ rect: CGRect, by delta: CGSize, keepAspect: Bool, minimum: CGFloat = 8) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if movesLeft { minX = min(rect.minX + delta.width, maxX - minimum) }
        if movesRight { maxX = max(rect.maxX + delta.width, minX + minimum) }
        if movesBottom { minY = min(rect.minY + delta.height, maxY - minimum) }
        if movesTop { maxY = max(rect.maxY + delta.height, minY + minimum) }
        var result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if keepAspect, isCorner, rect.width > 0, rect.height > 0 {
            let scale = max(result.width / rect.width, result.height / rect.height)
            let size = CGSize(width: rect.width * scale, height: rect.height * scale)
            result = CGRect(
                x: movesLeft ? rect.maxX - size.width : rect.minX,
                y: movesBottom ? rect.maxY - size.height : rect.minY,
                width: size.width, height: size.height
            )
        }
        return result
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
