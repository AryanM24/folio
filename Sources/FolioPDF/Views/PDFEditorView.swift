import FolioKit
import PDFKit
public import SwiftUI

/// The PDF editor window: page sidebar, the PDF canvas with its floating toolbar,
/// inspector and find bar, and the status bar.
public struct PDFEditorView: View {
    @ObservedObject private var document: PDFFileDocument
    @State private var model: PDFEditorModel
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.undoManager) private var undoManager

    public init(document: PDFFileDocument) {
        self.document = document
        _model = State(initialValue: PDFEditorModel(document: document))
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            PDFSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 196, max: 320)
        } detail: {
            VStack(spacing: 0) {
                canvas
                PDFStatusBar(model: model)
            }
        }
        .frame(minWidth: 760, idealWidth: 1180, minHeight: 520, idealHeight: 860)
        .toolbar { PDFWindowToolbar(model: model) }
        .focusedSceneValue(\.pdfEditor, model)
        .sheet(isPresented: $model.showingSignatureSheet) { SignatureSheet(model: model) }
        .onAppear(perform: appeared)
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    private var canvas: some View {
        PDFKitView(model: model)
            .overlay(alignment: .bottom) {
                AnnotationToolbar(model: model).padding(.bottom, 16)
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 12) {
                    if model.findVisible { FindBar(model: model) }
                    if model.showsInspector { AnnotationInspector(model: model) }
                }
                .padding(16)
                .animation(Hero.animation, value: model.findVisible)
                .animation(Hero.animation, value: model.showsInspector)
            }
            .overlay {
                if let message = model.busyMessage { BusyOverlay(LocalizedStringKey(message)) }
            }
    }

    private func appeared() {
        model.undoManager = undoManager
        let elapsed = ContinuousClock.now - document.loadedAt
        model.log.info("Opened \(model.pageCount) pages; parse to first paint \(elapsed, privacy: .public)")
        DispatchQueue.main.async { model.pdfView?.window?.makeFirstResponder(model.pdfView) }
    }
}

extension PDFEditorModel {
    /// The inspector floats over the canvas while there is something to style.
    var showsInspector: Bool {
        selectedAnnotation != nil || (tool != .select && tool != .redact)
    }
}

/// The PDF editor of the key window, for ``PDFCommands``. (Written out instead of
/// `@Entry` because the Command Line Tools ship without SwiftUI's macro plugin.)
struct PDFEditorFocusKey: FocusedValueKey {
    typealias Value = PDFEditorModel
}

extension FocusedValues {
    var pdfEditor: PDFEditorModel? {
        get { self[PDFEditorFocusKey.self] }
        set { self[PDFEditorFocusKey.self] = newValue }
    }
}
