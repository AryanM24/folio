import AppKit
import FolioKit
import PDFKit
import UniformTypeIdentifiers

/// Print, export and document properties.
///
/// Exports serialise in the background under the document lock (see ``PDFAccess``),
/// so the window stays responsive on large files.
extension PDFEditorModel {
    func printDocument() {
        commitFormEdit()
        pdfView?.print(with: NSPrintInfo.shared, autoRotate: true)
    }

    /// A copy with every annotation and form value burned into the pages.
    func exportFlattened() async {
        let access = document.access
        await Exporter.save(suggestedName: "\(title) (flattened)", type: .pdf, window: pdfView?.window) {
            try access.withLock(PDFOperations.flattenedData)
        }
    }

    /// A copy with images recompressed for screen. The open document is unchanged.
    func exportReducedSize() async {
        let access = document.access
        await Exporter.save(suggestedName: "\(title) (smaller)", type: .pdf, window: pdfView?.window) {
            try access.withLock(PDFOperations.compressedData)
        }
    }

    /// The target pages as a new PDF.
    func extractSelectedPages() async {
        let access = document.access
        let indices = targetPages
        let name = indices.count == 1 ? "\(title) page \(indices[0] + 1)" : "\(title) pages"
        await Exporter.save(suggestedName: name, type: .pdf, window: pdfView?.window) {
            try access.withLock { try PDFOperations.data(PDFOperations.extract(indices, from: $0)) }
        }
    }

    /// The target pages as PNG or JPEG files in a folder the user picks.
    func exportPageImages(as type: UTType) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the \(type == .png ? "PNG" : "JPEG") images"
        guard let window = pdfView?.window, await panel.beginSheetModal(for: window) == .OK, let folder = panel.url else { return }
        let access = document.access
        let indices = targetPages
        let base = title
        busyMessage = "Exporting images…"
        defer { busyMessage = nil }
        do {
            let written = try await Task.detached {
                try access.withLock { pdf in
                    try indices.compactMap { index -> URL? in
                        guard let page = pdf.page(at: index),
                            let image = Rasterizer.displayImage(page, scale: 2),
                            let data = Rasterizer.encode(image, as: type)
                        else { return nil }
                        let url = FolioTool.unique(
                            in: folder, name: "\(base) page \(index + 1)", ext: type.preferredFilenameExtension ?? "png")
                        try data.write(to: url, options: .atomic)
                        return url
                    }
                }
            }.value
            NSWorkspace.shared.activateFileViewerSelecting(written)
        } catch {
            show(error, title: "Couldn't export images")
        }
    }

    // MARK: Document properties

    /// Title, author, subject or keywords from the PDF's info dictionary.
    func attribute(_ key: PDFDocumentAttribute) -> String {
        let value = pdf.documentAttributes?[key]
        if let words = value as? [String] { return words.joined(separator: ", ") }
        return value as? String ?? ""
    }

    /// Sets one property as an undo step. Keywords are stored as a list.
    func setAttribute(_ key: PDFDocumentAttribute, to text: String) {
        let old = attribute(key)
        guard text != old else { return }
        mutate { pdf in
            var attributes = pdf.documentAttributes ?? [:]
            if text.isEmpty {
                attributes[key] = nil
            } else if key == .keywordsAttribute {
                attributes[key] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                attributes[key] = text
            }
            pdf.documentAttributes = attributes
        }
        registerUndo("Change Properties") { $0.setAttribute(key, to: old) }
    }

    // MARK: Zoom and layout

    func zoomIn() { pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.zoomOut(nil) }
    func actualSize() {
        pdfView?.autoScales = false
        pdfView?.scaleFactor = 1
    }

    /// Page width fills the view (PDFKit's auto scale in continuous mode).
    func fitWidth() { pdfView?.autoScales = true }

    /// The whole current page fits in the view.
    func fitPage() {
        guard let view = pdfView, let page = currentPage else { return }
        let size = Geometry.displaySize(crop: page.bounds(for: .cropBox), rotation: page.rotation)
        let available = view.bounds.insetBy(dx: 24, dy: 24).size
        guard size.width > 0, size.height > 0 else { return }
        view.autoScales = false
        view.scaleFactor = min(available.width / (size.width * (twoUp ? 2 : 1)), available.height / size.height)
        view.go(to: page)
    }

    func setTwoUp(_ on: Bool) {
        twoUp = on
        pdfView?.displayMode = on ? .twoUpContinuous : .singlePageContinuous
    }
}
