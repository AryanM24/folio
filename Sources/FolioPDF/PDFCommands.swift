public import SwiftUI

/// The "PDF" menu: every editor command with its shortcut, acting on the key
/// window's PDF. Mount it once in the app: `.commands { PDFCommands() }`.
///
/// Items are disabled when the key window isn't a PDF, so their shortcuts fall
/// through to other editors' menus. Annotation tools use ⌃⌘ (Preview's
/// convention) to keep plain keys free for typing in text boxes and form fields.
public struct PDFCommands: Commands {
    @FocusedValue(\.pdfEditor) private var editor

    public init() {}

    public var body: some Commands {
        CommandMenu("PDF") {
            Group { items }.disabled(editor == nil)
        }
    }

    @ViewBuilder private var items: some View {
        Group {
            Menu("Annotate") {
                ForEach(AnnotationTool.allCases) { tool in
                    Button(tool.title) { editor?.choose(tool) }
                        .keyboardShortcut(tool.key, modifiers: [.control, .command])
                }
            }
            Button("Insert Stamp…") { editor?.showingStamps = true }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button("Insert Signature") { editor?.insertSignature() }
                .keyboardShortcut("g", modifiers: [.control, .command])
            Button("Draw New Signature…") { editor?.showingSignatureSheet = true }
            Button("Insert Image…") { run { await $0.insertImageFromFile() } }
                .keyboardShortcut("i", modifiers: [.control, .command])
            Button("Delete Annotation") { editor?.deleteSelectedAnnotation() }
                .disabled(editor?.selectedAnnotation == nil)
        }
        Divider()
        Group {
            Button("Insert Blank Page") { editor?.insertBlankPage() }
                .keyboardShortcut("n", modifiers: [.option, .command])
            Button("Insert Pages from File…") { run { await $0.insertPagesFromFile() } }
                .keyboardShortcut("n", modifiers: [.shift, .option, .command])
            Button("Duplicate Pages") { editor?.duplicateSelectedPages() }
                .keyboardShortcut("d", modifiers: [.option, .command])
            Button("Delete Pages") { editor?.deleteSelectedPages() }
                .keyboardShortcut(.delete, modifiers: [.option, .command])
            Button("Rotate Left") { editor?.rotateLeft() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Rotate Right") { editor?.rotateRight() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Extract Pages…") { run { await $0.extractSelectedPages() } }
                .keyboardShortcut("e", modifiers: [.option, .command])
            Button("Recognize Text") { run { await $0.recognizeTextOnSelectedPages() } }
                .keyboardShortcut("t", modifiers: [.option, .command])
            Button("Recognize Text on All Scanned Pages") { run { await $0.recognizeTextOnAllPages() } }
            Button("Flatten Form") { editor?.flattenForm() }
        }
        Divider()
        Group {
            Button("Find…") { editor?.showFind() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { editor?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { editor?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.shift, .command])
            Button("Go to Page…") { editor?.showingGoTo = true }
                .keyboardShortcut("g", modifiers: [.option, .command])
        }
        Divider()
        Group {
            Button("Zoom In") { editor?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { editor?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { editor?.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Fit Page") { editor?.fitPage() }
                .keyboardShortcut("9", modifiers: .command)
            Button("Fit Width") { editor?.fitWidth() }
                .keyboardShortcut("9", modifiers: [.option, .command])
            Button("Single Page") { editor?.setTwoUp(false) }
                .keyboardShortcut("1", modifiers: [.option, .command])
            Button("Two Pages") { editor?.setTwoUp(true) }
                .keyboardShortcut("2", modifiers: [.option, .command])
        }
        Divider()
        Group {
            Button("Document Properties…") { editor?.showingInfo = true }
                .keyboardShortcut("i", modifiers: [.option, .command])
            Button("Print PDF…") { editor?.printDocument() }
            Button("Export as Flattened PDF…") { run { await $0.exportFlattened() } }
            Button("Export Pages as PNG…") { run { await $0.exportPageImages(as: .png) } }
            Button("Export Pages as JPEG…") { run { await $0.exportPageImages(as: .jpeg) } }
            Button("Reduce File Size…") { run { await $0.exportReducedSize() } }
        }
    }

    private func run(_ action: @escaping @MainActor (PDFEditorModel) async -> Void) {
        guard let editor else { return }
        Task { await action(editor) }
    }
}
