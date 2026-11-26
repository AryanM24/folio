import AppKit
import FolioKit
import Observation
import PDFKit
import SwiftUI

/// State and commands for one PDF window.
///
/// The view layer (SwiftUI chrome and ``FolioPDFView``) reads this and calls its
/// methods; it never edits the `PDFDocument` directly. That gives one place where
/// every mutation takes the document lock (so autosave never sees a half edit) and
/// registers its undo (so autosave happens at all). The methods are split by area:
/// `+Pages`, `+Annotations`, `+Search`, `+Forms`, `+Export`, `+Recognize`.
@Observable
final class PDFEditorModel {
    let document: PDFFileDocument
    var pdf: PDFDocument { document.pdf }

    /// The canvas. Weak: AppKit owns views.
    @ObservationIgnored weak var pdfView: FolioPDFView?
    /// The window's undo manager, which is the document's (set by the view).
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored let thumbnails = ThumbnailCache()
    @ObservationIgnored let log = Log.make("PDF")

    // MARK: Tools and selection

    /// The active annotation tool. Changing it ends any annotation selection.
    var tool: AnnotationTool = .select {
        didSet { if tool != .select { select(nil) } }
    }
    /// Last used style per tool, so the pen remembers its color.
    var styles: [AnnotationTool: AnnotationStyle] = [:]
    /// The annotation the inspector edits and the overlay outlines.
    /// Set it through `select(_:)`, which also loads the inspector's values.
    var selectedAnnotation: PDFAnnotation?
    /// The selected annotation's style as last read or set (PDFAnnotation isn't observable).
    var selectionStyle = AnnotationStyle.defaults(for: .select)
    /// Its text, for text boxes and notes.
    var selectionText = ""
    @ObservationIgnored var styleBeforeEdit: AnnotationAppearance?
    @ObservationIgnored var pendingFormEdit: FormEdit?

    // MARK: Navigation and display

    /// Bumped on every change to pages or annotations, so lists and the status bar refresh.
    private(set) var revision = 0
    var currentPageIndex = 0
    var scale: CGFloat = 1
    var twoUp = false
    var sidebarVisible = true
    var sidebarTab: SidebarTab = .pages
    /// Pages selected in the thumbnail sidebar, by index. Page commands act on these,
    /// or on the current page when the set is empty.
    var selectedPages: Set<Int> = []

    // MARK: Search

    var findVisible = false
    var query = ""
    var matches: [PDFSelection] = []
    var matchIndex = 0
    var searching = false
    /// Bumped by ⌘F so the find field takes focus even when already visible.
    var findFocusRequest = 0
    @ObservationIgnored var findObservers: [any NSObjectProtocol] = []

    // MARK: Panels and progress

    var showingSignatureSheet = false
    var showingInfo = false
    var showingGoTo = false
    var showingStamps = false
    /// Non-nil while a long operation runs ("Recognizing text…").
    var busyMessage: String?
    /// Moves keyboard focus to the inspector's text field after creating a text box.
    var focusTextRequest = 0

    enum SidebarTab: Hashable { case pages, outline }

    init(document: PDFFileDocument) {
        self.document = document
    }

    /// Reads `revision` so SwiftUI views refresh when pages are added or removed.
    var pageCount: Int {
        _ = revision
        return pdf.pageCount
    }
    var currentPage: PDFPage? { pdf.page(at: currentPageIndex) }

    /// Indices page commands apply to: the sidebar selection, else the current page.
    var targetPages: [Int] {
        let valid = selectedPages.filter { $0 < pageCount }
        return valid.isEmpty ? [currentPageIndex] : valid.sorted()
    }

    /// The style the inspector shows: the selection's, or the active tool's.
    var activeStyle: AnnotationStyle {
        selectedAnnotation != nil ? selectionStyle : style(for: tool)
    }

    func style(for tool: AnnotationTool) -> AnnotationStyle {
        styles[tool] ?? .defaults(for: tool)
    }

    /// The window title, for suggested export names.
    var title: String {
        let name = pdfView?.window?.title ?? ""
        return name.isEmpty ? "Untitled" : (name as NSString).deletingPathExtension
    }

    /// Keeps the page indicator and zoom readout in step with scrolling and zooming.
    func viewDidScroll() {
        guard let view = pdfView else { return }
        if let page = view.currentPage {
            let index = pdf.index(for: page)
            if index != NSNotFound, index != currentPageIndex { currentPageIndex = index }
        }
        if abs(view.scaleFactor - scale) > 0.001 { scale = view.scaleFactor }
    }

    isolated deinit {
        for observer in findObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Mutation plumbing

    /// Runs `change` with the document locked, then refreshes dependent UI.
    /// Every model method that edits the PDF goes through here.
    func mutate<T>(touching pages: [PDFPage] = [], _ change: (PDFDocument) -> T) -> T {
        let result = document.access.withLock(change)
        for page in pages {
            thumbnails.invalidate(page)
            pdfView?.annotationsChanged(on: page)
        }
        revision &+= 1
        pdfView?.refreshOverlay()
        return result
    }

    /// Registers `undo` (which must itself be undoable, so redo works) under `name`.
    func registerUndo(_ name: String, _ undo: @escaping @MainActor (PDFEditorModel) -> Void) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { undo(model) }
        }
        undoManager?.setActionName(name)
    }

    /// Shows an error as a sheet on the editor's window. Without a window (tests,
    /// a closing window) it is only logged: an app-modal alert would be worse.
    func show(_ error: any Error, title: String) {
        log.error("\(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        guard let window = pdfView?.window else { return }
        Alert.show(error, title: title, window: window)
    }
}

/// A `PDFPage`/`PDFDocument` handed to a background task that takes the document
/// lock before touching it.
nonisolated struct Unchecked<Value>: @unchecked Sendable {
    // @unchecked: only dereferenced inside `PDFAccess.withLock`.
    let value: Value
}
