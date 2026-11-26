import AppKit
import Observation
import FolioKit

/// Editor preferences, mirrored from the Settings window's "Editor" tab (`code.*` keys).
struct EditorSettings: Equatable {
    var fontSize: Double
    var wrapLines: Bool
    var showLineNumbers: Bool
    var tabWidth: Int
    var showInvisibles: Bool

    enum Key {
        static let fontSize = "code.fontSize", wrapLines = "code.wrapLines", showLineNumbers = "code.showLineNumbers"
        static let tabWidth = "code.tabWidth", showInvisibles = "code.showInvisibles"
    }
    static let defaultFontSize = 13.0
}

/// Owns one window's AppKit text stack and publishes what the status bar shows.
///
/// SwiftUI keeps this in `@State`, so the text view, its layout and the highlighter's cache
/// survive view updates and switching to Preview and back. Commands (menu items, toolbar,
/// shortcuts) are methods here, found through `FocusedValues.codeEditor`.
@Observable
final class EditorController: NSObject {
    // MARK: Status (observed by SwiftUI)

    /// Zero-based.
    private(set) var caretLine = 0
    /// One-based, with tabs expanded.
    private(set) var caretColumn = 1
    private(set) var selectionLength = 0
    private(set) var lineCount = 1
    private(set) var wordCount = 0
    private(set) var characterCount = 0
    /// For JSON files: the first syntax error, if any; `jsonChecked` once validation ran.
    var jsonIssue: JSONTools.Issue?
    var jsonChecked = false
    /// Top visible source line, for preview scroll sync.
    private(set) var topLine = 0
    /// Rendered preview body (Markdown) or source (HTML/SVG).
    private(set) var previewHTML = ""
    var showsGoToLine = false
    var find = FindState()
    /// Set by the view while the preview pane is on screen; rendering pauses otherwise.
    var previewVisible = false {
        didSet { if previewVisible, !oldValue { schedulePreview(immediately: true) } }
    }

    // MARK: AppKit stack

    @ObservationIgnored let highlighter = SyntaxHighlighter()
    @ObservationIgnored private(set) var textView: CodeTextView?
    @ObservationIgnored private(set) var scrollView: CodeScrollView?
    @ObservationIgnored private var ruler: LineNumberRuler?
    @ObservationIgnored weak var document: CodeDocument?
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet {
            guard undoManager !== oldValue else { return }
            let center = NotificationCenter.default
            for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                if let oldValue { center.removeObserver(self, name: name, object: oldValue) }
                if let undoManager { center.addObserver(self, selector: #selector(undoManagerDidChangeDocument), name: name, object: undoManager) }
            }
        }
    }
    @ObservationIgnored var fileURL: URL?
    @ObservationIgnored private(set) var settings = EditorSettings(fontSize: 13, wrapLines: true, showLineNumbers: true, tabWidth: 4, showInvisibles: false)
    @ObservationIgnored private(set) var language: Language = .plain
    @ObservationIgnored private var bracketRanges: [NSRange] = []
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var jsonTask: Task<Void, Never>?
    @ObservationIgnored let log = Log.make("Code")

    /// Builds the text stack the first time; afterwards returns the same views.
    func makeScrollView(document: CodeDocument, settings: EditorSettings) -> NSScrollView {
        if let scrollView { return scrollView }
        self.document = document
        self.settings = settings
        language = document.language

        // TextKit 1: non-contiguous layout keeps big files fast, it draws in `draw(_:)` (so
        // window snapshots and printing see the text), and its temporary attributes color text
        // without touching the document.
        let textView = CodeTextView(usingTextLayoutManager: false)
        let layoutManager = CodeLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.showsInvisibles = settings.showInvisibles
        textView.textContainer?.replaceLayoutManager(layoutManager)
        textView.controller = self
        textView.language = language
        textView.indentStyle = document.indent
        configure(textView)

        let scrollView = CodeScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CodeTheme.background
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        if let storage = textView.textStorage {
            storage.setAttributedString(NSAttributedString(string: document.loadedText, attributes: baseAttributes()))
            document.liveText = storage
            highlighter.reset(text: storage.mutableString, lexer: language.lexer)
            storage.delegate = self
        }

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        ruler.controller = self
        ruler.font = .monospacedDigitSystemFont(ofSize: max(9, settings.fontSize - 2), weight: .regular)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = settings.showLineNumbers

        self.textView = textView
        self.scrollView = scrollView
        self.ruler = ruler
        applyWrap()
        lineCount = highlighter.lines.count
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        scheduleStats(immediately: true)
        scheduleJSONCheck()
        return scrollView
    }

    private func configure(_ textView: CodeTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFontPanel = false
        textView.drawsBackground = true
        textView.backgroundColor = CodeTheme.background
        textView.insertionPointColor = CodeTheme.accent
        textView.selectedTextAttributes = [.backgroundColor: CodeTheme.selection]
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.textContainer?.lineFragmentPadding = 6
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.typingAttributes = baseAttributes()
        textView.setAccessibilityLabel("Editor")
        textView.setAccessibilityRoleDescription("source editor")
    }

    /// Font, tab stops and line spacing for the whole document. Colors come from rendering
    /// attributes, so the stored text keeps one uniform style.
    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)
        let style = NSMutableParagraphStyle()
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        style.defaultTabInterval = space * CGFloat(max(1, settings.tabWidth))
        style.tabStops = []
        style.lineHeightMultiple = 1.2
        return [.font: font, .paragraphStyle: style, .foregroundColor: CodeTheme.foreground]
    }

    // MARK: Settings and language

    func apply(_ new: EditorSettings) {
        guard new != settings, let textView, let scrollView else { return }
        let old = settings
        settings = new
        if old.fontSize != new.fontSize || old.tabWidth != new.tabWidth, let storage = textView.textStorage {
            let attributes = baseAttributes()
            storage.beginEditing()
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            textView.typingAttributes = attributes
            ruler?.font = .monospacedDigitSystemFont(ofSize: max(9, new.fontSize - 2), weight: .regular)
        }
        if old.wrapLines != new.wrapLines { applyWrap() }
        if old.showLineNumbers != new.showLineNumbers {
            scrollView.rulersVisible = new.showLineNumbers
            scrollView.tile()
        }
        if old.showInvisibles != new.showInvisibles, let layoutManager = textView.layoutManager as? CodeLayoutManager {
            layoutManager.showsInvisibles = new.showInvisibles
            textView.needsDisplay = true
        }
        ruler?.needsDisplay = true
    }

    private func applyWrap() {
        guard let textView, let scrollView, let container = textView.textContainer else { return }
        let wrap = settings.wrapLines
        scrollView.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        container.widthTracksTextView = wrap
        if !wrap {
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        scrollView.tile()
    }

    func setLanguage(_ new: Language) {
        guard new != language, let textView else { return }
        language = new
        textView.language = new
        highlighter.setLexer(new.lexer)
        if let layoutManager = textView.layoutManager {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: textView.text.length))
        }
        colorizeVisible()
        jsonIssue = nil
        jsonChecked = false
        scheduleJSONCheck()
        schedulePreview(immediately: true)
    }

    func setIndent(_ style: IndentStyle) {
        document?.indent = style
        textView?.indentStyle = style
    }

    // MARK: Status

    private func updateCaret() {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let lines = highlighter.lines
        let line = lines.line(containing: selection.location)
        let lineStart = lines.start(ofLine: line)
        var column = 1
        let text = textView.text
        let tabWidth = max(1, settings.tabWidth)
        // Expand tabs so the column matches what's on screen; capped for huge lines.
        let end = min(selection.location, lineStart + 10_000)
        if end > lineStart {
            for index in lineStart..<end {
                column += text.character(at: index) == 9 ? tabWidth - (column - 1) % tabWidth : 1
            }
        }
        let selected = textView.selectedRanges.reduce(0) { $0 + $1.rangeValue.length }
        if caretLine != line { caretLine = line }
        if caretColumn != column { caretColumn = column }
        if selectionLength != selected { selectionLength = selected }
    }

    /// Highlights the bracket next to the caret and its partner.
    private func updateBracketMatch() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        for range in bracketRanges where range.upperBound <= textView.text.length {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        bracketRanges = []
        let selection = textView.selectedRange()
        guard selection.length == 0, textView.selectedRanges.count == 1 else { return }
        let text = textView.text
        for index in [selection.location - 1, selection.location] {
            if let match = TextEditing.matchingBracket(in: text, at: index) {
                bracketRanges = [NSRange(location: index, length: 1), NSRange(location: match, length: 1)]
                break
            }
        }
        for range in bracketRanges {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: CodeTheme.bracket, forCharacterRange: range)
        }
    }

    /// Characters currently on screen, plus a screen's worth above and below so scrolling
    /// rarely shows uncolored text.
    private var visibleCharacterRange: NSRange? {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        let visible = textView.visibleRect
        let padded = visible.insetBy(dx: 0, dy: -visible.height).offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: padded, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    func colorizeVisible() {
        guard let textView, let layoutManager = textView.layoutManager, let range = visibleCharacterRange else { return }
        highlighter.colorize(range, in: textView.text, layoutManager: layoutManager)
    }

    /// Word and character counts, off the main thread and debounced while typing.
    private func scheduleStats(immediately: Bool = false) {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled, let text = self?.textView?.textStorage?.string else { return }
            let stats = await Task.detached(priority: .utility) { TextStats.count(text) }.value
            guard !Task.isCancelled, let self else { return }
            self.wordCount = stats.words
            self.characterCount = stats.characters
        }
    }

    private func scheduleJSONCheck() {
        jsonTask?.cancel()
        guard language == .json, let storage = textView?.textStorage, storage.length < 20_000_000 else { return }
        jsonTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let text = self?.textView?.textStorage?.string else { return }
            let issue = await Task.detached(priority: .utility) { JSONTools.validate(text) }.value
            guard !Task.isCancelled, let self else { return }
            self.jsonIssue = issue
            self.jsonChecked = true
        }
    }

    func schedulePreview(immediately: Bool = false) {
        previewTask?.cancel()
        guard previewVisible, language.hasPreview else { return }
        let language = self.language
        previewTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled, let text = self?.textView?.textStorage?.string else { return }
            let html = await Task.detached(priority: .userInitiated) {
                language == .markdown ? MarkdownRenderer.render(text) : text
            }.value
            guard !Task.isCancelled, let self else { return }
            self.previewHTML = html
            self.updateTopLine()
        }
    }

    @objc private func didScroll() {
        colorizeVisible()
        ruler?.needsDisplay = true
        if previewVisible { updateTopLine() }
    }

    private func updateTopLine() {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let point = NSPoint(x: 0, y: max(0, textView.visibleRect.minY - textView.textContainerOrigin.y))
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let line = highlighter.lines.line(containing: layoutManager.characterIndexForGlyph(at: glyph))
        if line != topLine { topLine = line }
    }

    /// Marks the document edited, which schedules the one-second autosave.
    ///
    /// The architecture's rule is that registering undo does this, but SwiftUI's
    /// `ReferenceFileDocument` doesn't pick up NSTextView's undo registrations (verified:
    /// typing left the window clean and nothing was written, even on quit). So the editor
    /// tells the window's `NSDocument` directly, which is what NSDocument does for itself when
    /// it observes its own undo manager.
    func noteChange() {
        (textView?.window?.windowController?.document as? NSDocument)?.updateChangeCount(.changeDone)
    }

    /// Undoing an encoding or line-ending change doesn't touch the text, so catch it here.
    @objc private func undoManagerDidChangeDocument() { noteChange() }

    /// Logs how long the file took from read to first paint (see docs/editors/code.md).
    func didFirstDraw() {
        guard let document, document.byteCount > 0 else { return }
        let elapsed = ContinuousClock.now - document.openedAt
        let ms = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        log.notice("Opened \(document.byteCount, privacy: .public) bytes, first paint after \(ms, privacy: .public) ms")
    }

    /// Hands the final text back to the document when the window closes.
    func tearDown() {
        if let text = textView?.textStorage?.string { document?.editorWillClose(text: text) }
        NotificationCenter.default.removeObserver(self)
        statsTask?.cancel()
        previewTask?.cancel()
        jsonTask?.cancel()
    }
}

// MARK: - Delegates

/// Text storage callbacks arrive on the main thread: the storage is only edited by its text view.
extension EditorController: @preconcurrency NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        highlighter.didEdit(textStorage.mutableString, editedRange: editedRange, delta: delta)
    }
}

extension EditorController: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        noteChange()
        colorizeVisible()
        let count = highlighter.lines.count
        if lineCount != count {
            lineCount = count
            ruler?.updateThickness()
        }
        ruler?.needsDisplay = true
        scheduleStats()
        scheduleJSONCheck()
        schedulePreview()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateCaret()
        updateBracketMatch()
        textView?.needsDisplay = true
        ruler?.needsDisplay = true
    }

    /// Edits register on the document's undo manager, which is what marks the window edited
    /// and triggers autosave.
    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager ?? view.window?.undoManager
    }
}

/// State of the regular-expression Find & Replace bar.
struct FindState {
    var isVisible = false
    var query = ""
    var replacement = ""
    var isRegex = false
    var matchCase = false
    var status = ""
    var isError = false
}

/// Word and character counts. Words are runs of non-whitespace, which is what people expect
/// from prose and close enough for code.
nonisolated enum TextStats {
    static func count(_ text: String) -> (words: Int, characters: Int) {
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return (words, text.count)
    }
}
