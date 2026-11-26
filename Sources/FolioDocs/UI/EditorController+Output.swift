import AppKit
import FolioKit
import OSLog

nonisolated private let log = Log.make("Docs")

/// Export, Print and the system panels the editor opens.
extension DocumentEditorController {
    /// File name without extension, for export suggestions.
    private var baseName: String {
        let window = textView?.window
        return window?.representedURL?.deletingPathExtension().lastPathComponent
            ?? window?.title.split(separator: ".").first.map(String.init)
            ?? "Untitled"
    }

    private func snapshot() -> DocumentSnapshot? {
        guard let storage, let document else { return nil }
        return DocumentSnapshot(text: NSAttributedString(attributedString: storage), attributes: document.attributes, page: document.page)
    }

    /// Asks where to save, then writes the document in `format`. Never changes the
    /// document's own file or format.
    func export(_ format: DocFormat) {
        guard let snapshot = snapshot() else { return }
        let window = textView?.window
        Task {
            let url = await Exporter.save(suggestedName: baseName, type: format.contentType, window: window) {
                switch format {
                case .pdf:
                    return try await MainActor.run { try PDFRenderer.pdf(snapshot.text, page: snapshot.page) }
                default:
                    return try DocumentCodec.data(snapshot.text, attributes: snapshot.attributes, page: snapshot.page, as: format)
                }
            }
            if let url { log.info("Exported \(format.rawValue, privacy: .public) to \(url.path, privacy: .private)") }
        }
    }

    /// Prints real pages with the document's paper and margins.
    func print() {
        guard let snapshot = snapshot() else { return }
        let view = PaginatedView(text: snapshot.text, page: snapshot.page)
        let operation = NSPrintOperation(view: view, printInfo: view.printInfo())
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = baseName
        if let window = textView?.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    func showFonts() {
        focusText()
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    /// Opens the system color panel aimed at the text color (the text view handles
    /// `changeColor:`) or, for highlights, at the highlight.
    func showColors(highlight: Bool = false) {
        focusText()
        let panel = NSColorPanel.shared
        if highlight {
            ColorPanelTarget.shared.onChange = { [weak self] color in self?.setHighlight(color) }
            panel.setTarget(ColorPanelTarget.shared)
            panel.setAction(#selector(ColorPanelTarget.colorChanged(_:)))
        } else {
            panel.setTarget(nil)
            panel.setAction(nil)
        }
        panel.orderFront(nil)
    }

    func focusText() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}

/// Receives the color panel's action when it edits highlights rather than text color.
final class ColorPanelTarget: NSObject {
    static let shared = ColorPanelTarget()
    var onChange: ((NSColor) -> Void)?
    @objc func colorChanged(_ sender: NSColorPanel) { onChange?(sender.color) }
}
