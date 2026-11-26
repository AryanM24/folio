public import SwiftUI
import FolioKit

/// The editor window for text, code and Markdown files.
public struct CodeEditorView: View {
    @ObservedObject private var document: CodeDocument

    public init(document: CodeDocument) { self.document = document }

    public var body: some View {
        // A reverted document is a new object; give it a fresh editor rather than patching one.
        CodeEditorScreen(document: document).id(ObjectIdentifier(document))
    }
}

/// Editor, Split or Preview, for files that have a preview.
enum PreviewMode: Hashable { case editor, split, preview }

struct CodeEditorScreen: View {
    @ObservedObject var document: CodeDocument
    @State private var controller = EditorController()
    @State private var mode: PreviewMode

    @AppStorage(EditorSettings.Key.fontSize) private var fontSize = EditorSettings.defaultFontSize
    @AppStorage(EditorSettings.Key.wrapLines) private var wrapLines = true
    @AppStorage(EditorSettings.Key.showLineNumbers) private var showLineNumbers = true
    @AppStorage(EditorSettings.Key.tabWidth) private var tabWidth = 4
    @AppStorage(EditorSettings.Key.showInvisibles) private var showInvisibles = false

    @Environment(\.undoManager) private var undoManager
    @Environment(\.documentConfiguration) private var configuration

    init(document: CodeDocument) {
        self.document = document
        _mode = State(initialValue: document.language == .markdown ? .split : .editor)
    }

    private var settings: EditorSettings {
        EditorSettings(fontSize: fontSize, wrapLines: wrapLines, showLineNumbers: showLineNumbers, tabWidth: tabWidth, showInvisibles: showInvisibles)
    }

    private var effectiveMode: PreviewMode { document.language.hasPreview ? mode : .editor }

    var body: some View {
        VStack(spacing: 0) {
            if controller.find.isVisible {
                FindReplaceBar(controller: controller)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                if effectiveMode != .preview {
                    CodeTextEditor(document: document, controller: controller, settings: settings,
                                   language: document.language, undoManager: undoManager,
                                   isEditable: configuration?.isEditable ?? true)
                        .frame(minWidth: 240, maxWidth: .infinity)
                }
                if effectiveMode == .split {
                    Rectangle().fill(Hero.separator).frame(width: 1)
                }
                if effectiveMode != .editor {
                    preview.frame(minWidth: 240, maxWidth: .infinity)
                }
            }
            CodeStatusBar(document: document, controller: controller)
        }
        .background(Hero.surface)
        .animation(Hero.animation, value: controller.find.isVisible)
        .toolbar { toolbar }
        .focusedSceneValue(\.codeEditor, controller)
        .sheet(isPresented: $controller.showsGoToLine) {
            GoToLineSheet(lineCount: controller.lineCount) { line, column in controller.goTo(line: line, column: column) }
        }
        .onAppear {
            controller.fileURL = configuration?.fileURL
            controller.previewVisible = effectiveMode != .editor
            // Files opened without a recognizable name (e.g. from stdin) get one more chance.
            if document.language == .plain, let url = configuration?.fileURL {
                let detected = Language.detect(fileName: url.lastPathComponent, firstLine: String(document.text.prefix(200)))
                if detected != .plain { document.language = detected }
            }
        }
        .onChange(of: effectiveMode) { _, new in controller.previewVisible = new != .editor }
        .onChange(of: configuration?.fileURL) { _, url in controller.fileURL = url }
        .onDisappear { controller.tearDown() }
    }

    @ViewBuilder private var preview: some View {
        let kind: PreviewPane.Kind = switch document.language {
        case .html: .html
        case .svg: .svg
        default: .markdown
        }
        PreviewPane(kind: kind, content: controller.previewHTML,
                    title: configuration?.fileURL?.deletingPathExtension().lastPathComponent ?? "Preview",
                    baseURL: configuration?.fileURL?.deletingLastPathComponent(),
                    topLine: controller.topLine)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if document.language.hasPreview {
            ToolbarItem(placement: .principal) {
                HeroTabs([
                    (PreviewMode.editor, "Editor", "text.alignleft"),
                    (PreviewMode.split, "Split", "rectangle.split.2x1"),
                    (PreviewMode.preview, "Preview", "eye"),
                ], selection: $mode)
                .accessibilityLabel("View mode")
            }
        }
        if document.language == .markdown {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("HTML…") { controller.export(.html) }
                    Button("PDF…") { controller.export(.pdf) }
                    Button("Word Document…") { controller.export(.docx) }
                    Divider()
                    Button("Print…") { controller.printDocument() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export as HTML, PDF or Word")
            }
        }
        if document.language == .json {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { controller.formatJSON() } label: { Label("Format JSON", systemImage: "text.alignleft") }
                    .help("Format JSON ⌥⇧⌘F")
                Button { controller.minifyJSON() } label: { Label("Minify JSON", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .help("Minify JSON")
            }
        }
    }
}

/// Hosts the controller's AppKit text stack.
struct CodeTextEditor: NSViewRepresentable {
    let document: CodeDocument
    let controller: EditorController
    let settings: EditorSettings
    let language: Language
    let undoManager: UndoManager?
    let isEditable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        controller.undoManager = undoManager
        return controller.makeScrollView(document: document, settings: settings)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        controller.undoManager = undoManager
        controller.apply(settings)
        controller.setLanguage(language)
        controller.textView?.isEditable = isEditable
    }
}

/// The focused window's code editor, for ``CodeCommands``. A plain key rather than
/// `@Entry`, whose macro plugin isn't in the Command Line Tools.
struct CodeEditorFocusKey: FocusedValueKey {
    typealias Value = EditorController
}

extension FocusedValues {
    var codeEditor: EditorController? {
        get { self[CodeEditorFocusKey.self] }
        set { self[CodeEditorFocusKey.self] = newValue }
    }
}
