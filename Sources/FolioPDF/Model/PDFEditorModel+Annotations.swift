import AppKit
import FolioKit
import PDFKit

/// Creating, selecting and editing annotations.
extension PDFEditorModel {
    // MARK: Selection

    func select(_ annotation: PDFAnnotation?) {
        selectedAnnotation = annotation
        if let annotation {
            selectionStyle = AnnotationAppearance.style(of: annotation)
            selectionText = annotation.contents ?? ""
        }
        pdfView?.refreshOverlay()
    }

    // MARK: Add and remove

    /// Adds `annotation` to `page` as one undo step, optionally selecting it.
    func add(_ annotation: PDFAnnotation, to page: PDFPage, name: String, select shouldSelect: Bool = false) {
        mutate(touching: [page]) { _ in page.addAnnotation(annotation) }
        registerUndo(name) { $0.remove(annotation, name: name) }
        if shouldSelect { select(annotation) }
    }

    func remove(_ annotation: PDFAnnotation, name: String = "Delete Annotation") {
        guard let page = annotation.page else { return }
        if selectedAnnotation === annotation { select(nil) }
        mutate(touching: [page]) { _ in page.removeAnnotation(annotation) }
        registerUndo(name) { $0.add(annotation, to: page, name: name) }
    }

    func deleteSelectedAnnotation() {
        if let selectedAnnotation { remove(selectedAnnotation) }
    }

    // MARK: Move and resize

    /// Moves or resizes during a drag. Not undoable on its own: the drag ends with
    /// ``setBounds(_:to:from:)``, which records one step for the whole gesture.
    func setBoundsLive(_ annotation: PDFAnnotation, to rect: CGRect) {
        document.access.withLock { _ in annotation.bounds = rect }
        pdfView?.refreshOverlay()
    }

    /// Commits a move or resize from `old` to `rect` as one undo step.
    func setBounds(_ annotation: PDFAnnotation, to rect: CGRect, from old: CGRect) {
        guard rect != old, let page = annotation.page else { return }
        mutate(touching: [page]) { _ in annotation.bounds = rect }
        registerUndo("Move Annotation") { $0.setBounds(annotation, to: old, from: rect) }
    }

    /// Arrow keys: 1 pt, or 10 pt with Shift.
    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let annotation = selectedAnnotation, AnnotationKind(annotation).isMovable else { return }
        let old = annotation.bounds
        setBounds(annotation, to: old.offsetBy(dx: dx, dy: dy), from: old)
    }

    // MARK: Creating from tools

    /// Highlight, underline or strike out `selection`. One undo step for all lines.
    func applyMarkup(_ tool: AnnotationTool, to selection: PDFSelection) {
        let pairs = AnnotationFactory.markup(tool, for: selection, style: style(for: tool))
        guard !pairs.isEmpty else { return }
        mutate(touching: pairs.map(\.0)) { _ in
            for (page, annotation) in pairs { page.addAnnotation(annotation) }
        }
        registerUndo(tool.title) { model in
            for (_, annotation) in pairs { model.remove(annotation, name: tool.title) }
        }
        pdfView?.clearSelection()
    }

    func addInk(_ points: [CGPoint], on page: PDFPage) {
        guard points.count > 1 || tool == .pen,
            let annotation = AnnotationFactory.ink(points: points, style: style(for: tool))
        else { return }
        add(annotation, to: page, name: tool.title)
    }

    /// Shapes, text boxes and redaction all start as a dragged rectangle.
    func finishDrag(from start: CGPoint, to end: CGPoint, on page: PDFPage) {
        let rect = Geometry.rect(from: start, to: end)
        let isClick = rect.width < 4 && rect.height < 4
        switch tool {
        case .redact:
            guard !isClick else { return }
            redact(rect, on: page)
        case .textBox:
            let style = style(for: .textBox)
            let box = isClick ? AnnotationFactory.defaultTextBox(at: start, fontSize: style.fontSize) : rect
            let annotation = AnnotationFactory.textBox(in: box, style: style)
            finishCreating(annotation, on: page, name: "Add Text Box")
            focusTextRequest += 1
        case .rectangle, .ellipse, .line, .arrow:
            guard !isClick else { return }
            let annotation = AnnotationFactory.shape(tool, from: start, to: end, style: style(for: tool))
            finishCreating(annotation, on: page, name: "Add \(tool.title)")
        default:
            break
        }
    }

    func addNote(at point: CGPoint, on page: PDFPage) {
        let annotation = AnnotationFactory.note(at: point, style: style(for: .note))
        finishCreating(annotation, on: page, name: "Add Note")
        focusTextRequest += 1
    }

    /// One-shot tools hand back to Select with the new annotation selected, so the
    /// inspector shows it and it can be adjusted right away.
    private func finishCreating(_ annotation: PDFAnnotation, on page: PDFPage, name: String) {
        tool = .select
        add(annotation, to: page, name: name, select: true)
    }

    // MARK: Images, stamps and signatures

    /// Places `image` in the middle of what's visible, selected for moving.
    func place(_ image: CGImage, size: CGSize, name: String) {
        guard
            let (page, center) = pdfView?.visibleCenter()
                ?? currentPage.map({ ($0, CGPoint(x: $0.bounds(for: .cropBox).midX, y: $0.bounds(for: .cropBox).midY)) })
        else { return }
        let bounds = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        tool = .select
        add(ImageAnnotation(image: image, bounds: bounds, name: name), to: page, name: "Add \(name)", select: true)
    }

    func insertStamp(_ stamp: Stamp) {
        showingStamps = false
        guard let (image, size) = stamp.render() else { return }
        place(image, size: size, name: stamp.title)
    }

    /// Uses the saved signature, or asks for one first.
    func insertSignature() {
        guard let image = SignatureStore.load() else {
            showingSignatureSheet = true
            return
        }
        place(image, size: ImageAnnotation.size(for: image, maxSide: 180), name: "Signature")
    }

    func insertImageFromFile() async {
        guard let url = await Exporter.pick(types: [.image], multiple: false, window: pdfView?.window).first else { return }
        guard let image = PageFactory.image(at: url) else {
            show(FolioError("“\(url.lastPathComponent)” couldn't be read as an image."), title: "Couldn't insert image")
            return
        }
        place(image, size: ImageAnnotation.size(for: image, maxSide: 300), name: "Image")
    }

    // MARK: Inspector edits

    /// Inspector setter: restyles the selection, or sets the active tool's style.
    func updateStyle(_ style: AnnotationStyle) {
        guard let annotation = selectedAnnotation else {
            styles[tool] = style
            return
        }
        // Remember it for the next annotation of this kind, like Preview does.
        if let kindTool = AnnotationKind(annotation).tool { styles[kindTool] = style }
        if styleBeforeEdit != nil {
            selectionStyle = style
            document.access.withLock { _ in AnnotationAppearance.apply(style, to: annotation) }
            if let page = annotation.page { pdfView?.annotationsChanged(on: page) }
        } else {
            restyle(annotation, to: style)
        }
    }

    /// Slider drags apply live and record one undo step when released.
    func beginStyleEdit() {
        guard let annotation = selectedAnnotation, styleBeforeEdit == nil else { return }
        styleBeforeEdit = AnnotationAppearance(annotation)
    }

    func endStyleEdit() {
        guard let annotation = selectedAnnotation, let before = styleBeforeEdit else { return }
        styleBeforeEdit = nil
        let after = AnnotationAppearance(annotation)
        registerUndo("Change Style") { $0.setAppearance(annotation, to: before, from: after) }
        if let page = annotation.page { mutate(touching: [page]) { _ in } }
    }

    private func restyle(_ annotation: PDFAnnotation, to style: AnnotationStyle) {
        let before = AnnotationAppearance(annotation)
        guard let page = annotation.page else { return }
        mutate(touching: [page]) { _ in AnnotationAppearance.apply(style, to: annotation) }
        selectionStyle = style
        let after = AnnotationAppearance(annotation)
        registerUndo("Change Style") { $0.setAppearance(annotation, to: before, from: after) }
    }

    func setAppearance(_ annotation: PDFAnnotation, to appearance: AnnotationAppearance, from current: AnnotationAppearance) {
        guard let page = annotation.page else { return }
        mutate(touching: [page]) { _ in appearance.restore(on: annotation) }
        if selectedAnnotation === annotation { selectionStyle = AnnotationAppearance.style(of: annotation) }
        registerUndo("Change Style") { $0.setAppearance(annotation, to: current, from: appearance) }
    }

    /// Text of the selected text box or note. Each change is an undo step, so every
    /// keystroke also marks the document for autosave.
    func setText(_ text: String, of annotation: PDFAnnotation) {
        let old = annotation.contents ?? ""
        guard text != old, let page = annotation.page else { return }
        mutate(touching: [page]) { _ in annotation.contents = text }
        if selectedAnnotation === annotation { selectionText = text }
        registerUndo("Typing") { $0.setText(old, of: annotation) }
    }
}
