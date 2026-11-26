import AppKit
import FolioKit
public import SwiftUI

/// The document editor window: outline sidebar, paper canvas with the floating
/// formatting toolbar, and a status bar with counts and zoom.
public struct RichTextEditorView: View {
    @ObservedObject private var document: RichTextDocument
    @State private var controller = DocumentEditorController()
    @AppStorage("docs.showsOutline") private var showsOutline = true
    @AppStorage("docs.wrapsToWindow") private var wrapsToWindow = false

    public init(document: RichTextDocument) { self.document = document }

    public var body: some View {
        HStack(spacing: 0) {
            if showsOutline {
                OutlineSidebar(controller: controller)
                    .frame(width: 220)
                    .overlay(alignment: .trailing) { Rectangle().fill(Hero.separator).frame(width: 1) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    PaperEditor(document: document, controller: controller, page: document.page, wrapsToWindow: wrapsToWindow)
                    FormattingToolbar(controller: controller)
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                }
                DocumentStatusBar(controller: controller)
            }
        }
        .background(Hero.backgroundSecondary)
        .frame(minWidth: 560, idealWidth: 1100, minHeight: 360, idealHeight: 820)
        .animation(Hero.animation, value: showsOutline)
        .toolbar { toolbarContent }
        .focusedSceneValue(\.documentEditor, controller)
        .onAppear {
            controller.showsOutline = showsOutline
            controller.wrapsToWindow = wrapsToWindow
        }
        .onChange(of: controller.showsOutline) { _, value in showsOutline = value }
        .onChange(of: controller.wrapsToWindow) { _, value in wrapsToWindow = value }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                controller.showsOutline.toggle()
            } label: {
                Label(showsOutline ? "Hide Outline" : "Show Outline", systemImage: "sidebar.left")
            }
            .help(showsOutline ? "Hide outline ⌃⌘S" : "Show outline ⌃⌘S")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Paper", selection: Binding(get: { document.page.paper }, set: { controller.setPaper($0) })) {
                    Text(PageSetup.Paper.letter.title).tag(PageSetup.Paper.letter)
                    Text(PageSetup.Paper.a4.title).tag(PageSetup.Paper.a4)
                    if document.page.paper == .custom { Text(PageSetup.Paper.custom.title).tag(PageSetup.Paper.custom) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Wrap to Window", isOn: Bindable(controller).wrapsToWindow)
            } label: {
                Label("Page", systemImage: "doc.plaintext")
            }
            .help("Paper size and layout")
            Menu {
                ForEach(DocFormat.exportable) { format in
                    Button(format.title + "…") { controller.export(format) }
                }
                Divider()
                Button("Print…") { controller.print() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export or print")
        }
    }
}

/// Words, characters, reading time and pages on the left; zoom on the right.
private struct DocumentStatusBar: View {
    let controller: DocumentEditorController

    var body: some View {
        let stats = controller.stats
        StatusBar {
            Text("\(stats.words.formatted()) \(stats.words == 1 ? "word" : "words")")
            Text("\(stats.characters.formatted()) characters")
            Text("\(stats.readingMinutes) min read")
            Text("\(stats.pages.formatted()) \(stats.pages == 1 ? "page" : "pages")")
                .help("Estimated printed pages")
            Spacer()
            Button {
                controller.zoomOut()
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom out")
            .help("Zoom out ⌘<")
            Menu {
                ForEach(DocumentEditorController.zoomLevels, id: \.self) { level in
                    Button("\(Int(level * 100))%") { controller.zoom = level }
                }
            } label: {
                Text("\(Int((controller.zoom * 100).rounded()))%").monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Zoom")
            .accessibilityValue("\(Int((controller.zoom * 100).rounded())) percent")
            Button {
                controller.zoomIn()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom in")
            .help("Zoom in ⌘>")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document statistics")
    }
}
