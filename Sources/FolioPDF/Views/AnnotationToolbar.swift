import FolioKit
import SwiftUI

/// The floating HeroUI tool pill over the page area.
struct AnnotationToolbar: View {
    @Bindable var model: PDFEditorModel

    var body: some View {
        HeroToolbar {
            tool(.select)
            HeroToolbarDivider()
            tool(.highlight)
            tool(.underline)
            tool(.strikeOut)
            HeroToolbarDivider()
            tool(.pen)
            tool(.highlighter)
            HeroToolbarDivider()
            tool(.textBox)
            tool(.note)
            tool(.rectangle)
            tool(.ellipse)
            tool(.line)
            tool(.arrow)
            HeroToolbarDivider()
            action("Stamp", symbol: "seal", help: "Stamp ⌃⌘S") { model.showingStamps = true }
                .popover(isPresented: $model.showingStamps, arrowEdge: .top) { StampPicker(model: model) }
            action("Signature", symbol: "signature", help: "Signature ⌃⌘G") { model.insertSignature() }
                .contextMenu {
                    Button("Draw New Signature…") { model.showingSignatureSheet = true }
                    Button("Clear Saved Signature") { SignatureStore.clear() }
                }
            action("Image", symbol: "photo", help: "Insert Image ⌃⌘I") { Task { await model.insertImageFromFile() } }
            HeroToolbarDivider()
            tool(.redact)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotation tools")
    }

    private func tool(_ tool: AnnotationTool) -> some View {
        let selected = model.tool == tool
        return Button {
            model.choose(tool)
        } label: {
            Label {
                Text(tool.title)
            } icon: {
                Image(systemName: tool.symbol).foregroundStyle(selected ? Hero.accent : Hero.foreground)
            }
        }
        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: selected))
        .help("\(tool.title) \(tool.shortcutLabel)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func action(_ title: String, symbol: String, help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(title, systemImage: symbol) }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
            .help(help)
    }
}

extension PDFEditorModel {
    /// Toolbar and menu entry point. Markup tools apply straight away to text that is
    /// already selected, like Preview; otherwise they wait for a selection.
    func choose(_ newTool: AnnotationTool) {
        tool = newTool
        if newTool.isMarkup, let selection = pdfView?.currentSelection, !(selection.string ?? "").isEmpty {
            applyMarkup(newTool, to: selection)
        }
        pdfView?.window?.makeFirstResponder(pdfView)
    }
}

/// Grid of stamps; choosing one drops it on the visible page.
struct StampPicker: View {
    let model: PDFEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stamps").font(.system(size: 13, weight: .semibold)).foregroundStyle(Hero.foreground)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(Stamp.allCases) { stamp in
                    Button {
                        model.insertStamp(stamp)
                    } label: {
                        StampPreview(stamp: stamp)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color.white, in: .rect(cornerRadius: Hero.Radius.xl))
                            .overlay { RoundedRectangle(cornerRadius: Hero.Radius.xl).strokeBorder(Hero.border) }
                    }
                    .buttonStyle(.plain)
                    .help(stamp.title)
                    .accessibilityLabel(stamp.title)
                }
            }
        }
        .padding(16)
        .frame(width: 288)
    }
}

/// A stamp rendered exactly as it will appear on the page.
struct StampPreview: View {
    let stamp: Stamp
    var body: some View {
        if let rendered = stamp.render() {
            Image(decorative: rendered.image, scale: 3)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 104, maxHeight: 30)
        }
    }
}
