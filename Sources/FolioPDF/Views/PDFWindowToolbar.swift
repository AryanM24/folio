import FolioKit
import PDFKit
import SwiftUI

/// The native window toolbar: zoom, layout, page commands, find, properties, export.
/// Native controls on purpose: the window's toolbar should look like every Mac app's.
struct PDFWindowToolbar: ToolbarContent {
    @Bindable var model: PDFEditorModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.zoomOut() }
                .help("Zoom Out ⌘−")
            Menu {
                Button("Actual Size") { model.actualSize() }
                Button("Fit Width") { model.fitWidth() }
                Button("Fit Page") { model.fitPage() }
            } label: {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .help("Actual size, fit width or fit page")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoomIn() }
                .help("Zoom In ⌘+")

            Picker("Layout", selection: Binding(get: { model.twoUp }, set: { model.setTwoUp($0) })) {
                Label("Single Page", systemImage: "rectangle.portrait").tag(false)
                Label("Two Pages", systemImage: "rectangle.split.2x1").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Page layout")

            Menu {
                PageMenuItems(model: model)
            } label: {
                Label("Pages", systemImage: "doc.on.doc")
            }
            .help("Page commands")

            Button("Find", systemImage: "magnifyingglass") {
                model.findVisible ? model.hideFind() : model.showFind()
            }
            .help("Find ⌘F")

            Button("Properties", systemImage: "info.circle") { model.showingInfo.toggle() }
                .help("Document properties ⌥⌘I")
                .popover(isPresented: $model.showingInfo, arrowEdge: .bottom) { DocumentInfoView(model: model) }

            Menu {
                ExportMenuItems(model: model)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Print and export")
        }
    }
}

/// Page commands, shared by the toolbar menu and the PDF menu bar menu.
struct PageMenuItems: View {
    let model: PDFEditorModel
    var body: some View {
        Button("Insert Blank Page", systemImage: "doc.badge.plus") { model.insertBlankPage() }
        Button("Insert Pages from File…", systemImage: "doc.badge.arrow.up") { Task { await model.insertPagesFromFile() } }
        Divider()
        Button("Rotate Left", systemImage: "rotate.left") { model.rotateLeft() }
        Button("Rotate Right", systemImage: "rotate.right") { model.rotateRight() }
        Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateSelectedPages() }
        Button("Delete", systemImage: "trash") { model.deleteSelectedPages() }
        Divider()
        Button("Extract to New PDF…", systemImage: "square.and.arrow.up.on.square") { Task { await model.extractSelectedPages() } }
        Button("Recognize Text", systemImage: "text.viewfinder") { Task { await model.recognizeTextOnSelectedPages() } }
        Button("Recognize Text on All Scanned Pages", systemImage: "doc.text.viewfinder") { Task { await model.recognizeTextOnAllPages() } }
        Button("Flatten Form", systemImage: "rectangle.and.pencil.and.ellipsis") { model.flattenForm() }
    }
}

/// Print and export commands.
struct ExportMenuItems: View {
    let model: PDFEditorModel
    var body: some View {
        Button("Print…", systemImage: "printer") { model.printDocument() }
        Divider()
        Button("Export as Flattened PDF…") { Task { await model.exportFlattened() } }
        Button("Export Pages as PNG…") { Task { await model.exportPageImages(as: .png) } }
        Button("Export Pages as JPEG…") { Task { await model.exportPageImages(as: .jpeg) } }
        Button("Reduce File Size…") { Task { await model.exportReducedSize() } }
    }
}

/// Title, author, subject and keywords, saved when a field loses focus or on Return.
struct DocumentInfoView: View {
    let model: PDFEditorModel
    @State private var values: [PDFDocumentAttribute: String] = [:]

    private let fields: [(PDFDocumentAttribute, String)] = [
        (.titleAttribute, "Title"),
        (.authorAttribute, "Author"),
        (.subjectAttribute, "Subject"),
        (.keywordsAttribute, "Keywords"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Document properties").font(.system(size: 13, weight: .semibold))
            ForEach(fields, id: \.0) { key, label in
                InspectorSection(LocalizedStringKey(label)) {
                    TextField(key == .keywordsAttribute ? "Separate with commas" : label, text: binding(key))
                        .textFieldStyle(.hero)
                        .onSubmit { commit(key) }
                }
            }
            Text("\(model.pageCount) pages").font(.system(size: 12)).foregroundStyle(Hero.muted)
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            for (key, _) in fields { values[key] = model.attribute(key) }
        }
        .onDisappear {
            for (key, _) in fields { commit(key) }
        }
    }

    private func binding(_ key: PDFDocumentAttribute) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func commit(_ key: PDFDocumentAttribute) {
        if let value = values[key] { model.setAttribute(key, to: value) }
    }
}
