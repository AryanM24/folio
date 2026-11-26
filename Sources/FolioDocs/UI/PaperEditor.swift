import AppKit
import FolioKit
import OSLog
import SwiftUI

nonisolated private let log = Log.make("Docs")

/// Hosts the AppKit editor (scroll view → paper canvas → text view) in SwiftUI.
///
/// The text view edits the document's own `NSTextStorage`, and its undo manager is
/// the document window's (`undoManager(for:)` below), so typing marks the document
/// edited and autosave runs about a second later.
struct PaperEditor: NSViewRepresentable {
    let document: RichTextDocument
    let controller: DocumentEditorController
    let page: PageSetup
    let wrapsToWindow: Bool

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = DocsTextView.make(storage: document.storage)
        textView.delegate = context.coordinator
        textView.onPrint = { [weak controller] in controller?.print() }
        if document.storage.length > 0 {
            textView.typingAttributes = document.storage.attributes(at: 0, effectiveRange: nil).filter {
                $0.key != .attachment && $0.key != .link
            }
        }

        let canvas = PaperCanvas(textView: textView)
        canvas.page = page
        canvas.wrapsToWindow = wrapsToWindow

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.minMagnification = DocumentEditorController.zoomLevels.first ?? 0.5
        scroll.maxMagnification = DocumentEditorController.zoomLevels.last ?? 3
        scroll.documentView = canvas
        canvas.observe(scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.magnified(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        controller.textView = textView
        controller.canvas = canvas
        controller.document = document
        controller.undoManager = context.environment.undoManager
        context.coordinator.undoManager = context.environment.undoManager

        DispatchQueue.main.async {
            canvas.layoutPaper()
            scroll.displayIfNeeded()
            log.info(
                "Opened \(document.storage.length) characters; read to first paint \(Int(Date().timeIntervalSince(document.openedAt) * 1000)) ms"
            )
            textView.window?.makeFirstResponder(textView)
            controller.selectionChanged()
        }
        Task { await controller.refresh() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.undoManager = context.environment.undoManager
        controller.undoManager = context.environment.undoManager
        guard let canvas = scroll.documentView as? PaperCanvas else { return }
        canvas.page = page
        canvas.wrapsToWindow = wrapsToWindow
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // The storage outlives the view (it belongs to the document); detach our layout
        // manager so it doesn't keep laying out for a closed window.
        if let canvas = scroll.documentView as? PaperCanvas, let layout = canvas.textView.layoutManager {
            canvas.textView.textStorage?.removeLayoutManager(layout)
        }
        NotificationCenter.default.removeObserver(coordinator)
    }

    /// Text view delegate: routes undo to the document and keeps SwiftUI state current.
    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: DocumentEditorController
        var undoManager: UndoManager?

        init(controller: DocumentEditorController) { self.controller = controller }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager ?? view.window?.undoManager
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.selectionChanged()
        }

        func textDidChange(_ notification: Notification) {
            controller.textChanged()
        }

        @objc func magnified(_ note: Notification) {
            guard let scroll = note.object as? NSScrollView else { return }
            controller.zoom = scroll.magnification
        }
    }
}
