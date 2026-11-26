import AppKit
import PDFKit

/// Find in document. Uses PDFKit's asynchronous search so a 500-page file never
/// freezes typing: matches stream in while the field stays responsive, the first one
/// is shown as soon as it's found, and all of them are highlighted when it finishes.
extension PDFEditorModel {
    /// Shows the find bar (⌘F). The bar focuses its own field.
    func showFind() {
        findVisible = true
        findFocusRequest += 1
        if let selected = pdfView?.currentSelection?.string, !selected.isEmpty, selected.count < 100 {
            query = selected
        }
    }

    func hideFind() {
        findVisible = false
        pdf.cancelFindString()
        matches = []
        searching = false
        pdfView?.highlightedSelections = nil
        pdfView?.window?.makeFirstResponder(pdfView)
    }

    /// Starts a new search, cancelling any in progress.
    func search(_ text: String) {
        pdf.cancelFindString()
        matches = []
        matchIndex = 0
        pdfView?.highlightedSelections = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searching = false
            return
        }
        observeFindIfNeeded()
        searching = true
        pdf.beginFindString(trimmed, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    func findNext() { step(by: 1) }
    func findPrevious() { step(by: -1) }

    private func step(by delta: Int) {
        guard !matches.isEmpty else {
            if !query.isEmpty, !searching { search(query) }
            return
        }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        reveal(matchIndex)
    }

    /// Scrolls to match `index` and selects it; the rest stay highlighted.
    private func reveal(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        let match = matches[index]
        pdfView?.setCurrentSelection(match, animate: false)
        pdfView?.go(to: match)
    }

    private func observeFindIfNeeded() {
        guard findObservers.isEmpty else { return }
        let center = NotificationCenter.default
        findObservers.append(
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: pdf, queue: .main) { [weak self] note in
                // Posted on the main queue; the box only carries the selection across the closure boundary.
                let match = Unchecked(value: note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection)
                MainActor.assumeIsolated { self?.found(match.value) }
            })
        findObservers.append(
            center.addObserver(forName: .PDFDocumentDidEndFind, object: pdf, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishedFind() }
            })
    }

    private func found(_ selection: PDFSelection?) {
        guard let selection, searching else { return }
        selection.color = NSColor.systemYellow.withAlphaComponent(0.55)
        matches.append(selection)
        if matches.count == 1 { reveal(0) }
    }

    private func finishedFind() {
        searching = false
        pdfView?.highlightedSelections = matches
        if let first = matches.first, pdfView?.currentSelection == nil { pdfView?.setCurrentSelection(first, animate: false) }
    }
}
