import AppKit
import FolioKit
import PDFKit

/// The value of a form field at one moment, for undo.
struct FormEdit {
    let widget: PDFAnnotation
    let text: String?
    let state: PDFWidgetCellState

    init(_ widget: PDFAnnotation) {
        self.widget = widget
        text = widget.widgetStringValue
        state = widget.buttonWidgetState
    }

    func differs(from other: FormEdit) -> Bool { text != other.text || state != other.state }
}

/// AcroForm filling. PDFKit edits widget values itself but doesn't tell the undo
/// manager, so autosave wouldn't notice. Folio records a field's value when the user
/// starts interacting with it, and when they leave it registers an undo step if the
/// value changed, which marks the document edited and schedules a save.
extension PDFEditorModel {
    /// Called when a click lands on a form field.
    func beginFormEdit(_ widget: PDFAnnotation) {
        commitFormEdit()
        pendingFormEdit = FormEdit(widget)
    }

    /// Called when editing ends: focus leaves the field, another click, window resigns.
    func commitFormEdit() {
        guard let before = pendingFormEdit else { return }
        pendingFormEdit = nil
        let after = FormEdit(before.widget)
        guard after.differs(from: before) else { return }
        registerUndo("Fill Form") { $0.setForm(to: before, from: after) }
        if let page = before.widget.page { thumbnails.invalidate(page) }
        mutate { _ in }
    }

    func setForm(to value: FormEdit, from current: FormEdit) {
        let widget = value.widget
        mutate(touching: widget.page.map { [$0] } ?? []) { _ in
            if let text = value.text { widget.widgetStringValue = text }
            widget.buttonWidgetState = value.state
        }
        registerUndo("Fill Form") { $0.setForm(to: current, from: value) }
    }

    /// Burns every form field's current value into its page, so the form prints the
    /// same everywhere and can no longer be changed. Other annotations stay editable.
    func flattenForm() {
        commitFormEdit()
        let widget = PDFAnnotationSubtype.widget.name
        let replacements: [(old: PDFPage, new: PDFPage)] = (0..<pageCount).compactMap { index in
            guard let page = pdf.page(at: index), page.annotations.contains(where: { $0.type == widget }),
                let flat = PageRebuilder.rebuild(page, burn: .formFields)
            else { return nil }
            return (page, flat)
        }
        guard !replacements.isEmpty else {
            show(FolioError("This PDF has no form fields to flatten."), title: "Nothing to flatten")
            return
        }
        replace(replacements, name: "Flatten Form")
    }
}
