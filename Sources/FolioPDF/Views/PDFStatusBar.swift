import FolioKit
import SwiftUI

/// "Page 3 of 12 · 125 %" plus what the active tool expects next.
/// Clicking the page number opens Go to Page.
struct PDFStatusBar: View {
    @Bindable var model: PDFEditorModel

    var body: some View {
        StatusBar {
            Button {
                model.showingGoTo = true
            } label: {
                Text("Page \(model.currentPageIndex + 1) of \(model.pageCount)")
            }
            .buttonStyle(.plain)
            .help("Go to Page ⌥⌘G")
            .popover(isPresented: $model.showingGoTo, arrowEdge: .top) { GoToPageView(model: model) }
            Text("\(Int((model.scale * 100).rounded())) %")
                .accessibilityLabel("Zoom \(Int((model.scale * 100).rounded())) percent")
            if model.selectedPages.count > 1 {
                Text("\(model.selectedPages.count) pages selected")
            }
            Spacer()
            Text(model.selectedAnnotation.map { "\(AnnotationKind($0).title) selected · ⌫ to delete" } ?? model.tool.hint)
                .lineLimit(1)
        }
    }
}

/// Popover with a page number field.
struct GoToPageView: View {
    let model: PDFEditorModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to page").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                TextField("1–\(model.pageCount)", text: $text)
                    .textFieldStyle(.hero)
                    .frame(width: 96)
                    .focused($focused)
                    .onSubmit(go)
                Button("Go", action: go)
                    .buttonStyle(.hero(.primary))
                    .disabled(Int(text) == nil)
            }
        }
        .padding(16)
        .onAppear {
            text = "\(model.currentPageIndex + 1)"
            focused = true
        }
    }

    private func go() {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
        model.go(toPage: number - 1)
        model.showingGoTo = false
    }
}
