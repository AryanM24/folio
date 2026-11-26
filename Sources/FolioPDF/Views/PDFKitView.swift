import PDFKit
import SwiftUI

/// Hosts ``FolioPDFView`` in SwiftUI and connects it to the model.
///
/// The model drives the view imperatively (zoom, go to page, highlight matches)
/// because those are PDFView commands, not state; so `updateNSView` has nothing to do.
struct PDFKitView: NSViewRepresentable {
    let model: PDFEditorModel

    func makeNSView(context: Context) -> FolioPDFView {
        let view = FolioPDFView(frame: .zero)
        view.document = model.pdf
        view.model = model
        model.pdfView = view
        view.setAccessibilityLabel("PDF pages")
        return view
    }

    func updateNSView(_ view: FolioPDFView, context: Context) {}

    static func dismantleNSView(_ view: FolioPDFView, coordinator: ()) {
        view.model?.commitFormEdit()
    }
}
