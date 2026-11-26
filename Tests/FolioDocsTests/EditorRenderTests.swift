import AppKit
import SwiftUI
import Testing

@testable import FolioDocs

/// Hosts the real editor view in an offscreen window to exercise the AppKit side:
/// the text view edits the document's storage, commands go through undo, and (with
/// `FOLIO_SAMPLES_DIR` set) light and dark renderings are saved for review.
@Suite("Editor", .serialized)
struct EditorRenderTests {
    /// A window showing `RichTextEditorView`, plus its controller once it attached.
    private func host(
        _ document: RichTextDocument, appearance: NSAppearance.Name = .aqua,
        size: NSSize = NSSize(width: 1100, height: 760)
    ) async throws -> (NSWindow, DocumentEditorController) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: RichTextEditorView(document: document))
        window.contentView = hosting
        window.orderBack(nil)
        try await settle()
        let textView = try #require(findTextView(in: hosting))
        let controller = try #require((textView.delegate as? PaperEditor.Coordinator)?.controller)
        return (window, controller)
    }

    private func settle(_ seconds: Double = 0.6) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    /// Outline and statistics are recomputed off the critical path after edits, so wait
    /// for them instead of guessing a delay: a fixed sleep flakes when the suite is busy.
    private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition(), Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    private func findTextView(in view: NSView) -> DocsTextView? {
        if let tv = view as? DocsTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }

    private func save(_ window: NSWindow, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["FOLIO_SAMPLES_DIR"], let view = window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    private func document(_ text: NSAttributedString) throws -> RichTextDocument {
        let doc = RichTextDocument()
        doc.storage.setAttributedString(text)
        return doc
    }

    @Test func rendersLightAndDark() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (window, controller) = try await host(try document(Fixtures.richDocument()), appearance: appearance)
            try await waitUntil { controller.outline.count == 5 && controller.stats.words > 30 }
            #expect(controller.outline.count == 5)
            #expect(controller.stats.words > 30)
            save(window, appearance == .aqua ? "editor-light" : "editor-dark")
            // Narrow windows switch to the compact toolbar.
            window.setContentSize(NSSize(width: 700, height: 600))
            try await settle(0.3)
            save(window, appearance == .aqua ? "editor-narrow-light" : "editor-narrow-dark")
            window.close()
        }
    }

    @Test func formattingCommandsEditStorageAndUndo() async throws {
        let doc = try document(Fixtures.paragraph("Hello world", .body))
        let (window, controller) = try await host(doc)
        defer { window.close() }
        let textView = try #require(controller.textView)
        let undo = UndoManager()
        controller.undoManager = undo
        (textView.delegate as? PaperEditor.Coordinator)?.undoManager = undo

        textView.setSelectedRange(NSRange(location: 0, length: 5))
        controller.toggleBold()
        #expect((doc.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isBold == true)
        #expect(undo.canUndo, "formatting registers undo, which is what triggers autosave")
        undo.undo()
        #expect((doc.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isBold == false)

        controller.applyStyle(.heading1)
        #expect(controller.selection.style == .heading1)
        controller.toggleList(.numbered)
        #expect(ListKind.of(doc.storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle) == .numbered)
        controller.toggleList(.numbered)
        #expect(ListKind.of(doc.storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle) == nil)

        textView.setSelectedRange(NSRange(location: doc.storage.length, length: 0))
        controller.insertTable(rows: 2, columns: 3)
        #expect(controller.selection.inTable)
        controller.editTable(.rowBelow)
        controller.editTable(.columnRight)
        let table = try #require(TableModel.read(from: doc.storage, at: textView.selectedRange().location))
        #expect(table.model.rowCount == 3 && table.model.columnCount == 4)
        controller.editTable(.deleteTable)
        #expect(!controller.selection.inTable)

        controller.insertHorizontalRule()
        controller.insertPageBreak()
        #expect(doc.storage.string.contains("\u{0C}"))
        controller.insertLink(URL(string: "https://folio.app")!)  // literal URL is valid
        #expect(doc.storage.string.contains("https://folio.app"))
        controller.setAlignment(.center)
        #expect(controller.selection.alignment == .center)
        try await settle(0.5)
        #expect(controller.stats.words >= 2)
    }

    @Test func paperFollowsPageSetupAndWrap() async throws {
        let doc = try document(Fixtures.richDocument())
        let (window, controller) = try await host(doc)
        defer { window.close() }
        let textView = try #require(controller.textView)
        #expect(textView.frame.width == 612)
        controller.setPaper(.a4)
        try await settle(0.3)
        #expect(abs(textView.frame.width - 595.28) < 0.5)
        controller.wrapsToWindow = true
        try await settle(0.3)
        #expect(textView.frame.width > 700, "fills the window beside the outline")
        save(window, "editor-wrapped")
        controller.wrapsToWindow = false
        controller.zoom = 0.75
        try await settle(0.5)
        save(window, "editor-zoomed")
    }

    /// The editor opens a 300+ page document and is interactive well within a second.
    @Test func largeDocumentOpensFast() async throws {
        let data = try DocumentCodec.data(Fixtures.longDocument(pages: 360), page: PageSetup(), as: .docx)
        let start = Date()
        let (text, _) = try DocumentCodec.read(data, as: .docx)
        let doc = try document(text)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RichTextEditorView(document: doc))
        window.orderBack(nil)
        window.displayIfNeeded()
        let elapsed = Date().timeIntervalSince(start)
        print("Opened and drew 360-page document in \(Int(elapsed * 1000)) ms")
        #expect(elapsed < 1)
        try await settle(1)
        window.close()
    }
}
