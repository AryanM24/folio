import AppKit
import FolioKit
public import SwiftUI

/// What the toolbar shows for the current selection.
struct SelectionState: Equatable {
    var style: TextStyle = .body
    var fontFamily = TextStyle.family
    var fontSize: CGFloat = 12
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    /// 1 superscript, -1 subscript, 0 normal.
    var baseline = 0
    var alignment: NSTextAlignment = .natural
    var lineSpacing: CGFloat = 1
    var list: ListKind?
    var inTable = false
    var imageSelected = false
    var hasSelection = false
    var link: URL?
}

/// The bridge between SwiftUI (toolbar, menus, outline, status bar) and the AppKit
/// text view for one document window.
///
/// Every edit goes through the text view (`shouldChangeText` / `didChangeText`), so
/// it is undoable with the window's undo manager and therefore autosaves.
@Observable
public final class DocumentEditorController {
    // MARK: State shown in SwiftUI

    var selection = SelectionState()
    var stats = TextStats.zero
    var outline: [OutlineItem] = []
    /// Index into `outline` of the section containing the caret.
    var currentHeading: Int?
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { applyZoom() } } }
    var wrapsToWindow = false { didSet { canvas?.wrapsToWindow = wrapsToWindow } }
    var showsOutline = true
    /// The link popover, opened by the toolbar button or Format › Add Link (⌘K).
    var showsLinkEditor = false

    static let zoomLevels: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    // MARK: AppKit side

    @ObservationIgnored weak var textView: DocsTextView?
    @ObservationIgnored weak var canvas: PaperCanvas?
    @ObservationIgnored weak var document: RichTextDocument?
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Attributes captured by Copy Style.
    @ObservationIgnored var copiedStyle: [NSAttributedString.Key: Any]?

    public init() {}

    var storage: NSTextStorage? { textView?.textStorage }

    // MARK: Selection

    /// Re-reads the attributes at the caret for the toolbar.
    func selectionChanged() {
        guard let textView, let storage else { return }
        let range = textView.selectedRange()
        var state = SelectionState()
        state.hasSelection = range.length > 0
        let attrs: [NSAttributedString.Key: Any]
        if range.length == 0 || storage.length == 0 {
            attrs = textView.typingAttributes
        } else {
            attrs = storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
        }
        let paragraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle
        let font = attrs[.font] as? NSFont
        state.style = TextStyle.detect(font: font, paragraph: paragraphStyle)
        state.fontFamily = font?.familyName ?? TextStyle.family
        state.fontSize = font?.pointSize ?? 12
        state.bold = font?.isBold ?? false
        state.italic = font?.isItalic ?? false
        state.underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
        state.strikethrough = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        let superscript = attrs[.superscript] as? Int ?? 0
        let offset = attrs[.baselineOffset] as? Double ?? 0
        state.baseline = superscript != 0 ? superscript.signum() : Int(offset.sign == .minus ? -1 : (offset > 0 ? 1 : 0))
        state.alignment = paragraphStyle?.alignment ?? .natural
        state.lineSpacing = (paragraphStyle?.lineHeightMultiple ?? 0) == 0 ? 1 : paragraphStyle?.lineHeightMultiple ?? 1
        state.list = ListKind.of(paragraphStyle)
        state.inTable = paragraphStyle?.textBlocks.contains { $0 is NSTextTableBlock } ?? false
        state.imageSelected = range.length == 1 && storage.attribute(.attachment, at: range.location, effectiveRange: nil) != nil
        state.link = (attrs[.link] as? URL) ?? (attrs[.link] as? String).flatMap(URL.init(string:))
        if state != selection { selection = state }
        updateCurrentHeading()
    }

    private func updateCurrentHeading() {
        guard let caret = textView?.selectedRange().location else { return }
        let index = outline.lastIndex { $0.location <= caret }
        if index != currentHeading { currentHeading = index }
    }

    // MARK: Derived data

    /// Recomputes stats (off the main thread) and the outline after edits settle.
    func textChanged() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Runs immediately on open and after the debounce on edits.
    func refresh() async {
        guard let storage else { return }
        let string = storage.string
        let stats = await Task.detached(priority: .utility) { TextStats(string: string) }.value
        if stats != self.stats { self.stats = stats }
        guard let storage = self.storage else { return }
        let outline = Outline.headings(in: storage)
        if outline != self.outline { self.outline = outline }
        updateCurrentHeading()
    }

    // MARK: Navigation

    /// Scrolls to a heading and puts the caret at its start.
    func reveal(_ item: OutlineItem) {
        guard let textView, let storage, item.location <= storage.length else { return }
        let range = NSRange(location: item.location, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
        textView.showFindIndicator(for: (storage.string as NSString).paragraphRange(for: range))
    }

    // MARK: View options

    func zoomIn() { zoom = Self.zoomLevels.first { $0 > zoom + 0.01 } ?? zoom }
    func zoomOut() { zoom = Self.zoomLevels.last { $0 < zoom - 0.01 } ?? zoom }

    private func applyZoom() {
        guard let scroll = canvas?.enclosingScrollView, abs(scroll.magnification - zoom) > 0.001 else { return }
        scroll.animator().magnification = zoom
    }

    /// Switches paper size as an undoable document change.
    func setPaper(_ paper: PageSetup.Paper) {
        guard let document else { return }
        document.setPage(document.page.with(paper: paper), undoManager: undoManager)
    }
}

// MARK: - Focused value

/// Key for the document editor in the key window, read by `DocumentCommands`.
/// (Spelled out rather than `@Entry`: the Command Line Tools ship without the
/// SwiftUI macro plugin.)
private struct DocumentEditorKey: FocusedValueKey {
    typealias Value = DocumentEditorController
}

public extension FocusedValues {
    /// The document editor in the key window, for menu commands.
    var documentEditor: DocumentEditorController? {
        get { self[DocumentEditorKey.self] }
        set { self[DocumentEditorKey.self] = newValue }
    }
}
