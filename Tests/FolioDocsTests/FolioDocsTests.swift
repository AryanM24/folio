import AppKit
import Testing
import UniformTypeIdentifiers

@testable import FolioDocs

// MARK: - Helpers

private func paragraphStyles(_ text: NSAttributedString) -> [NSParagraphStyle] {
    var out: [NSParagraphStyle] = []
    text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        if let p = value as? NSParagraphStyle { out.append(p) }
    }
    return out
}

private func hasBold(_ text: NSAttributedString, word: String) -> Bool {
    let range = (text.string as NSString).range(of: word)
    guard range.location != NSNotFound else { return false }
    return (text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?.isBold ?? false
}

private func roundTrip(
    _ text: NSAttributedString, _ format: DocFormat, page: PageSetup = PageSetup()
) throws -> (text: NSMutableAttributedString, attributes: DocumentCodec.Attributes) {
    let wrapper = try DocumentCodec.fileWrapper(text, page: page, as: format)
    return try DocumentCodec.read(wrapper, as: format)
}

// MARK: - Formats

@Suite("Formats")
struct FormatTests {
    @Test("Every editable format round-trips text and bold", arguments: DocFormat.editable)
    func roundTripsEditableFormats(_ format: DocFormat) throws {
        let (text, _) = try roundTrip(Fixtures.richDocument(), format)
        #expect(text.string.contains("Quarterly Report"))
        #expect(text.string.contains("Revenue grew 18% this quarter"))
        #expect(hasBold(text, word: "18%"))
    }

    @Test("Plain text and Markdown round-trip their text", arguments: [DocFormat.txt, .md])
    func roundTripsPlainFormats(_ format: DocFormat) throws {
        let (text, _) = try roundTrip(Fixtures.richDocument(), format)
        #expect(text.string.contains("Revenue grew"))
        #expect(text.string.contains("New customers"))
    }

    @Test func docxKeepsListsTablesAndHeadings() throws {
        let (text, _) = try roundTrip(Fixtures.richDocument(), .docx)
        let styles = paragraphStyles(text)
        #expect(styles.contains { ListKind.of($0) == .bullet })
        #expect(styles.contains { ListKind.of($0) == .numbered })
        #expect(styles.contains { $0.textBlocks.contains { $0 is NSTextTableBlock } })
        let model = try #require(TableModel.read(from: text, at: (text.string as NSString).range(of: "North").location))
        #expect(model.model.rowCount == 3)
        #expect(model.model.columnCount == 3)
        let headings = Outline.headings(in: text).map(\.title)
        #expect(headings == ["Quarterly Report", "Summary", "Highlights", "Next steps", "Numbers"])
        #expect(text.string.contains("\u{0C}"), "page break survives")
        let link = text.attribute(.link, at: (text.string as NSString).range(of: "details").location, effectiveRange: nil)
        #expect((link as? URL)?.absoluteString == "https://example.com" || (link as? String) == "https://example.com")
    }

    @Test func docxKeepsPageSetup() throws {
        let a4 = PageSetup().with(paper: .a4)
        let (_, attributes) = try roundTrip(Fixtures.richDocument(), .docx, page: a4)
        #expect(PageSetup(attributes: attributes).paper == .a4)
    }

    @Test func rtfKeepsPageSetupAndLists() throws {
        let a4 = PageSetup().with(paper: .a4)
        let (text, attributes) = try roundTrip(Fixtures.richDocument(), .rtf, page: a4)
        #expect(PageSetup(attributes: attributes).paper == .a4)
        #expect(paragraphStyles(text).contains { ListKind.of($0) == .checklist })
    }

    @Test func emptyFileOpensAsEmptyDocument() throws {
        let (text, _) = try DocumentCodec.read(Data(), as: .docx)
        #expect(text.length == 0)
    }

    @Test func damagedFileGivesPlainLanguageError() {
        #expect(throws: (any Error).self) { try DocumentCodec.read(Data("not a zip".utf8), as: .docx) }
    }

    @Test func formatLookupPrefersSpecificTypes() {
        #expect(DocFormat.format(for: .markdown) == .md)
        #expect(DocFormat.format(for: .rtfd) == .rtfd)
        #expect(DocFormat.format(for: .docx) == .docx)
        #expect(DocFormat.format(for: URL(fileURLWithPath: "/a/b.html")) == .html)
    }
}

// MARK: - Word specifics

@Suite("Word")
struct DocxTests {
    @Test func zipRoundTrip() throws {
        let entries = [
            ZipArchive.Entry(path: "a.txt", data: Data(String(repeating: "hello ", count: 200).utf8)),
            ZipArchive.Entry(path: "dir/b.bin", data: Data([0, 1, 2, 3])),
        ]
        let zip = ZipArchive.archive(entries)
        #expect(ZipArchive.read("a.txt", from: zip) == entries[0].data)
        #expect(ZipArchive.read("dir/b.bin", from: zip) == entries[1].data)
        #expect(ZipArchive.read("missing", from: zip) == nil)
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    /// A Word file whose heading gets its size and weight only from styles.xml, the way
    /// Word writes them; the system reader alone would show it as 12 pt body text.
    @Test func wordHeadingStylesAreApplied() throws {
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Intro</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Body text.</w:t></w:r></w:p></w:body></w:document>
            """
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
            <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>\
            <w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
            <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
            <w:rPr><w:b/><w:color w:val="2E74B5"/><w:sz w:val="32"/></w:rPr></w:style></w:styles>
            """
        let types = """
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
            """
        let rels = """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """
        let docRels = """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """
        let zip = ZipArchive.archive([
            .init(path: "[Content_Types].xml", data: Data(types.utf8)), .init(path: "_rels/.rels", data: Data(rels.utf8)),
            .init(path: "word/document.xml", data: Data(document.utf8)), .init(path: "word/styles.xml", data: Data(styles.utf8)),
            .init(path: "word/_rels/document.xml.rels", data: Data(docRels.utf8)),
        ])
        let (text, _) = try DocumentCodec.read(zip, as: .docx)
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 16)
        #expect(font.isBold)
        #expect(font.familyName == "Helvetica Neue")
        #expect(Outline.headings(in: text).map(\.title) == ["Intro"])
        let bodyFont = text.attribute(.font, at: (text.string as NSString).range(of: "Body").location, effectiveRange: nil) as? NSFont
        #expect(bodyFont?.pointSize == 11)
    }

    @Test func xmlEscaping() {
        #expect(DocxWriter.escape("a<b>&\"c\u{1}") == "a&lt;b&gt;&amp;&quot;c")
        #expect(DocxWriter.hex(NSColor(srgbRed: 1, green: 0, blue: 0.5, alpha: 1)) == "FF0080")
    }
}

// MARK: - Markdown

@Suite("Markdown")
struct MarkdownTests {
    @Test func exportsStructureAndInlineStyles() {
        let md = Markdown.string(from: Fixtures.richDocument())
        #expect(md.contains("# Quarterly Report"))
        #expect(md.contains("# Summary"))
        #expect(md.contains("## Highlights"))
        #expect(md.contains("### Numbers"))
        #expect(md.contains("Revenue grew **18%** *this quarter*[ (details)](https://example.com)."))
        #expect(md.contains("- New customers\n- Lower churn\n- Two launches"))
        #expect(md.contains("1. Hire\n2. Ship\n3. Measure"))
        #expect(md.contains("- [ ] Draft budget"))
        #expect(md.contains("| Region | Q1 | Q2 |\n| --- | --- | --- |\n| North | 120 | 140 |"))
        #expect(md.contains("> A quiet closing thought."))
        #expect(md.contains("```\nlet total = q1 + q2\n```"))
    }

    @Test func escapesMarkdownCharacters() {
        let md = Markdown.string(from: Fixtures.paragraph("2 * 3 = [six]", .body))
        #expect(md == "2 \\* 3 = \\[six\\]\n")
    }

    @Test func importsBlocksAndInlines() {
        let text = Markdown.attributedString(from: "# Title\n\nSome **bold** text.\n\n- one\n- two\n\n1. first\n- [x] done\n")
        #expect(Outline.headings(in: text).map(\.title) == ["Title"])
        #expect(hasBold(text, word: "bold"))
        let kinds = paragraphStyles(text).compactMap(ListKind.of)
        #expect(kinds.contains(.bullet) && kinds.contains(.numbered) && kinds.contains(.checklist))
        #expect(Markdown.string(from: text).contains("- [x] done"))
    }
}

// MARK: - Editing helpers

@Suite("Lists")
struct ListTests {
    @Test func toggleAddsAndRemovesList() {
        let body = NSMutableAttributedString()
        body.append(Fixtures.paragraph("a", .body))
        body.append(Fixtures.paragraph("b", .body))
        let listed = ListFormatting.toggle(.numbered, in: body)
        #expect(paragraphStyles(listed).allSatisfy { ListKind.of($0) == .numbered })
        let second = (listed.string as NSString).range(of: "b").location
        let start = (listed.string as NSString).paragraphRange(for: NSRange(location: second, length: 0)).location
        #expect(ListFormatting.itemNumber(at: start, in: listed) == 2)
        let removed = ListFormatting.toggle(.numbered, in: listed)
        #expect(removed.string == "a\nb\n")
        #expect(paragraphStyles(removed).allSatisfy { $0.textLists.isEmpty && $0.headIndent == 0 })
    }

    @Test func switchingKindReplacesList() {
        let bullets = Fixtures.list(["x", "y"], .bullet)
        let checks = ListFormatting.toggle(.checklist, in: bullets)
        #expect(paragraphStyles(checks).allSatisfy { ListKind.of($0) == .checklist })
        #expect(checks.string.hasSuffix("x\ny\n"))
    }

    @Test func checkboxToggles() throws {
        let style = try #require(paragraphStyles(Fixtures.list(["todo"], .checklist)).first)
        let checked = try #require(ListFormatting.toggledCheck(style))
        #expect(checked.textLists.last?.markerFormat == .check)
        #expect(ListFormatting.toggledCheck(checked)?.textLists.last?.markerFormat == .box)
        #expect(ListFormatting.toggledCheck(NSParagraphStyle.default) == nil)
    }

    @Test func indentNeverGoesNegative() {
        let indented = ListFormatting.indent(nil, by: 1)
        #expect(indented.headIndent == 36)
        let back = ListFormatting.indent(ListFormatting.indent(indented, by: -1), by: -1)
        #expect(back.headIndent == 0 && back.firstLineHeadIndent == 0)
    }
}

@Suite("Tables")
struct TableTests {
    private func cellText(_ model: TableModel) -> [[String]] {
        model.cells.map { $0.map { $0.string.trimmingCharacters(in: .newlines) } }
    }

    @Test func readsInsertsAndDeletes() throws {
        let rendered = Fixtures.table([["a", "b"], ["c", "d"]])
        var (model, range) = try #require(TableModel.read(from: rendered, at: 0))
        #expect(range == NSRange(location: 0, length: rendered.length))
        #expect(cellText(model) == [["a", "b"], ["c", "d"]])
        model.insertRow(at: 1)
        model.insertColumn(at: 2)
        #expect(model.rowCount == 3 && model.columnCount == 3)
        #expect(cellText(model) == [["a", "b", ""], ["", "", ""], ["c", "d", ""]])
        model.deleteRow(at: 1)
        model.deleteColumn(at: 0)
        #expect(cellText(model) == [["b", ""], ["d", ""]])
        let again = try #require(TableModel.read(from: model.render(), at: 0))
        #expect(cellText(again.model) == [["b", ""], ["d", ""]])
    }

    @Test func locatesCellsAndOffsets() throws {
        let rendered = Fixtures.table([["a", "b"], ["c", "d"]])
        let model = try #require(TableModel.read(from: rendered, at: 0)).model
        let offset = model.offset(ofRow: 1, column: 1)
        #expect((rendered.string as NSString).substring(with: NSRange(location: offset, length: 1)) == "d")
        let cell = try #require(TableModel.cell(in: rendered, at: offset))
        #expect(cell.row == 1 && cell.column == 1)
    }

    @Test func keepsLastRowAndColumn() {
        var model = TableModel(rows: 1, columns: 1, attributes: [:])
        model.deleteRow(at: 0)
        model.deleteColumn(at: 0)
        #expect(model.rowCount == 1 && model.columnCount == 1)
    }

    @Test func findsTableBetweenParagraphs() throws {
        let doc = NSMutableAttributedString()
        doc.append(Fixtures.paragraph("before", .body))
        doc.append(Fixtures.table([["x"]]))
        doc.append(Fixtures.paragraph("after", .body))
        let x = (doc.string as NSString).range(of: "x").location
        let (_, range) = try #require(TableModel.read(from: doc, at: x))
        #expect((doc.string as NSString).substring(with: range) == "x\n")
        #expect(TableModel.read(from: doc, at: 0) == nil)
    }
}

@Suite("Styles, stats and outline")
struct StyleTests {
    @Test("Each style is detected from its own attributes", arguments: TextStyle.allCases)
    func detectsOwnStyles(_ style: TextStyle) {
        let attrs = style.attributes()
        #expect(TextStyle.detect(font: attrs[.font] as? NSFont, paragraph: attrs[.paragraphStyle] as? NSParagraphStyle) == style)
    }

    @Test func applyStyleKeepsAlignment() {
        let text = NSMutableAttributedString(attributedString: Fixtures.paragraph("Centered", .body))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        text.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: text.length))
        TextStyle.apply(.heading1, to: text, paragraphsIn: NSRange(location: 0, length: 0))
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.alignment == .center)
        #expect(style?.headerLevel == 1)
        #expect((text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 20)
    }

    @Test func countsWordsCharactersAndPages() {
        let stats = TextStats(string: "Hello, world! Don't panic.\n\u{0C}Next")
        #expect(stats.words == 5)
        #expect(stats.characters == 30)
        #expect(stats.readingMinutes == 1)
        #expect(stats.pages == 2)
        #expect(TextStats(string: "").readingMinutes == 0)
        #expect(TextStats(string: String(repeating: "word ", count: 1200)).pages == 3)
    }

    @Test func outlineListsHeadingsWithLevels() {
        let items = Outline.headings(in: Fixtures.richDocument())
        #expect(items.map(\.level) == [0, 1, 2, 2, 3])
    }

    @Test func pageSetupReadsAndClampsAttributes() {
        let setup = PageSetup(attributes: [
            .paperSize: NSValue(size: NSSize(width: 595.28, height: 841.89)), .leftMargin: 36, .topMargin: -5,
        ])
        #expect(setup.paper == .a4)
        #expect(setup.margins.left == 36)
        #expect(setup.margins.top == 72)
        #expect(PageSetup(attributes: [:]).paper == .letter)
    }
}

// MARK: - PDF, conversion and performance

@Suite("Output")
struct OutputTests {
    @Test func pdfHasOnePagePerPageBreak() throws {
        let text = NSMutableAttributedString(attributedString: Fixtures.paragraph("One", .body))
        text.append(NSAttributedString(string: "\u{0C}Two\u{0C}Three\n", attributes: TextStyle.body.attributes()))
        let data = try PDFRenderer.pdf(text, page: PageSetup())
        let pdf = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))  // provider from in-memory data never fails
        #expect(pdf.numberOfPages == 3)
        let box = pdf.page(at: 1)?.getBoxRect(.mediaBox)
        #expect(box?.width == 612 && box?.height == 792)
    }

    @Test func longDocumentPaginates() throws {
        let data = try PDFRenderer.pdf(Fixtures.longDocument(pages: 10), page: PageSetup().with(paper: .a4))
        let pdf = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))  // see above
        #expect(pdf.numberOfPages >= 8)
        #expect(abs((pdf.page(at: 1)?.getBoxRect(.mediaBox).width ?? 0) - 595.28) < 1)
    }

    @Test("Converter writes next to the input without touching it", arguments: [DocFormat.md, .pdf, .html, .txt, .odt])
    func convertsFiles(_ format: DocFormat) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "folio-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "Report.docx")
        try DocumentCodec.data(Fixtures.richDocument(), page: PageSetup(), as: .docx).write(to: input)
        let before = try Data(contentsOf: input)
        let output = try await DocumentConverter.convert(input, to: format)
        #expect(output.lastPathComponent == "Report.\(format.fileExtension)")
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: input) == before)
        let again = try await DocumentConverter.convert(input, to: format)
        #expect(again.lastPathComponent == "Report 2.\(format.fileExtension)")
    }

    @Test func toolIsDeclared() {
        #expect(DocumentTools.all.map(\.id) == ["docs.convert"])
        #expect(DocumentTools.convert.accepts(URL(fileURLWithPath: "/x/a.docx")))
        #expect(DocumentTools.convert.accepts(URL(fileURLWithPath: "/x/a.md")))
        #expect(!DocumentTools.convert.accepts(URL(fileURLWithPath: "/x/a.png")))
    }

    /// The < 1 s open budget for a 300-page Word file: parse + style pass.
    @Test func largeDocumentOpensQuickly() throws {
        let data = try DocumentCodec.data(Fixtures.longDocument(pages: 360), page: PageSetup(), as: .docx)
        let start = Date()
        let (text, _) = try DocumentCodec.read(data, as: .docx)
        let elapsed = Date().timeIntervalSince(start)
        #expect(TextStats(string: text.string).words > 150_000)
        #expect(elapsed < 1, "opened in \(elapsed) s")
        if let dir = ProcessInfo.processInfo.environment["FOLIO_SAMPLES_DIR"] {
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "Long.docx"))
        }
    }

    /// With FOLIO_SAMPLES_DIR set, writes sample files for `scripts/snapshot.sh`.
    @Test func writesSamplesWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["FOLIO_SAMPLES_DIR"] else { return }
        let folder = URL(fileURLWithPath: dir)
        let doc = Fixtures.richDocument()
        for format in [DocFormat.docx, .rtf, .odt, .html, .md] {
            try DocumentCodec.data(doc, page: PageSetup(), as: format).write(to: folder.appending(path: "Sample.\(format.fileExtension)"))
        }
    }
}

@Test func newDocumentStartsEmpty() {
    let document = RichTextDocument()
    #expect(document.storage.length == 0)
    #expect(document.format == .docx)
}
