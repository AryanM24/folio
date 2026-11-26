import AppKit
import FolioKit
import PDFKit

/// Redaction and OCR: the two operations that rebuild page content.
extension PDFEditorModel {
    /// Permanently removes everything under `rect` on `page`. See ``Redactor`` for
    /// why the whole page becomes an image.
    func redact(_ rect: CGRect, on page: PDFPage) {
        guard let redacted = document.access.withLock({ _ in Redactor.redact(page, rects: [rect]) }) else {
            show(FolioError("Folio couldn't redact this page."), title: "Redaction failed")
            return
        }
        replace([(old: page, new: redacted)], name: "Redact")
    }

    /// Recognises text on the target pages (sidebar selection or current page).
    func recognizeTextOnSelectedPages() async {
        await recognizeText(on: targetPages.compactMap { pdf.page(at: $0) }, skipPagesWithText: false)
    }

    /// Recognises text on every page that doesn't have any yet (scans).
    func recognizeTextOnAllPages() async {
        await recognizeText(on: (0..<pageCount).compactMap { pdf.page(at: $0) }, skipPagesWithText: true)
    }

    /// Renders each page on the main actor (fast), runs Vision off it (slow), then
    /// swaps all the rebuilt pages in at once so the whole run is one undo step.
    /// Pages are tracked by identity, so reordering pages meanwhile is harmless.
    private func recognizeText(on pages: [PDFPage], skipPagesWithText: Bool) async {
        guard busyMessage == nil else { return }
        let candidates =
            skipPagesWithText
            ? pages.filter { ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            : pages
        guard !candidates.isEmpty else {
            show(FolioError("Every page already has selectable text."), title: "Nothing to recognize")
            return
        }
        var replacements: [(old: PDFPage, new: PDFPage)] = []
        var found = 0
        for (number, page) in candidates.enumerated() {
            busyMessage = "Recognizing text… \(number + 1) of \(candidates.count)"
            guard let image = document.access.withLock({ _ in Rasterizer.raster(page, scale: TextRecognizer.scale, annotations: false) })
            else { continue }
            do {
                let lines = try await TextRecognizer.recognize(image)
                guard !lines.isEmpty else { continue }
                found += lines.count
                if let rebuilt = document.access.withLock({ _ in TextRecognizer.addingTextLayer(to: page, lines: lines) }) {
                    replacements.append((page, rebuilt))
                }
            } catch {
                log.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        busyMessage = nil
        guard !replacements.isEmpty else {
            show(
                FolioError("Folio didn't find any text on \(candidates.count == 1 ? "this page" : "these pages")."), title: "No text found")
            return
        }
        replace(replacements, name: "Recognize Text")
        log.info("Recognized \(found) lines on \(replacements.count) pages")
    }
}
