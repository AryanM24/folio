import AppKit

/// Writes Word (.docx) files.
///
/// Why not `NSAttributedString.data(…, .officeOpenXML)`: the system's Word writer
/// drops lists, tables and heading styles (verified on macOS 26/27: a table written
/// and read back comes out as loose paragraphs). Autosave would then silently strip
/// them from any Word file opened in Folio. This writer covers what Folio edits:
/// paragraphs and runs (fonts, bold, italic, underline, strikethrough, color,
/// highlight, super/subscript), alignment, indents, spacing, heading/title styles,
/// lists, tables, links, images, page breaks, horizontal rules and page setup.
/// Reading still goes through the system reader, which handles all of these.
nonisolated struct DocxWriter {
    private let text: NSAttributedString
    private let page: PageSetup
    private var lists: [ObjectIdentifier: (id: Int, list: NSTextList)] = [:]
    private var relationships: [(id: String, type: String, target: String, external: Bool)] = []
    private var media: [ZipArchive.Entry] = []
    private var drawingID = 0

    /// A complete .docx package for `text`.
    static func data(from text: NSAttributedString, page: PageSetup) -> Data {
        var writer = DocxWriter(text: text, page: page)
        return writer.package()
    }

    private init(text: NSAttributedString, page: PageSetup) {
        self.text = text
        self.page = page
    }

    private mutating func package() -> Data {
        relationships.append(("rId1", "styles", "styles.xml", false))
        let body = bodyXML(text)
        let hasLists = !lists.isEmpty
        if hasLists { relationships.append(("rId2", "numbering", "numbering.xml", false)) }

        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="\(w)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\(sectionXML())</w:body></w:document>
            """
        let rels = relationships.map { r in
            let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(r.type)"
            return
                "<Relationship Id=\"\(r.id)\" Type=\"\(type)\" Target=\"\(Self.escape(r.target))\"\(r.external ? " TargetMode=\"External\"" : "")/>"
        }.joined()
        var overrides = """
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
            """
        if hasLists {
            overrides +=
                "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>"
        }
        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="png" ContentType="image/png"/>\(overrides)</Types>
            """
        let rootRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """
        var entries: [ZipArchive.Entry] = [
            .init(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            .init(path: "_rels/.rels", data: Data(rootRels.utf8)),
            .init(path: "word/document.xml", data: Data(document.utf8)),
            .init(path: "word/styles.xml", data: Data(Self.stylesXML.utf8)),
            .init(
                path: "word/_rels/document.xml.rels",
                data: Data(
                    """
                    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
                    """.utf8)),
        ]
        if hasLists { entries.append(.init(path: "word/numbering.xml", data: Data(numberingXML().utf8))) }
        entries += media
        return ZipArchive.archive(entries)
    }

    // MARK: Body

    private mutating func bodyXML(_ text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var xml = ""
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            if style?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true,
                let (table, tableRange) = TableModel.read(from: text, at: range.location)
            {
                xml += tableXML(table)
                location = NSMaxRange(tableRange)
                continue
            }
            xml += paragraphXML(text, range: range)
            location = NSMaxRange(range)
        }
        if ns.length == 0 { xml = "<w:p/>" }
        return xml
    }

    private mutating func tableXML(_ table: TableModel) -> String {
        let width = 5000 / max(1, table.columnCount)
        let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFC7\""
        var xml =
            "<w:tbl><w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>"
            + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) \(border)/>" }.joined()
            + "</w:tblBorders><w:tblCellMar><w:left w:w=\"108\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
            + String(
                repeating: "<w:gridCol w:w=\"\(Int(page.contentSize.width * 20) / max(1, table.columnCount))\"/>", count: table.columnCount)
            + "</w:tblGrid>"
        for row in table.cells {
            xml += "<w:tr>"
            for cell in row {
                let content = NSMutableAttributedString(attributedString: cell)
                Self.removeTableBlocks(from: content)
                var inner = bodyXML(content)
                if inner.isEmpty { inner = "<w:p/>" }
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"pct\"/></w:tcPr>\(inner)</w:tc>"
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    private static func removeTableBlocks(from text: NSMutableAttributedString) {
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let p = value as? NSParagraphStyle, !p.textBlocks.isEmpty,
                let copy = p.mutableCopy() as? NSMutableParagraphStyle
            else { return }
            copy.textBlocks = p.textBlocks.filter { !($0 is NSTextTableBlock) }
            text.addAttribute(.paragraphStyle, value: copy, range: range)
        }
    }

    private mutating func paragraphXML(_ text: NSAttributedString, range: NSRange) -> String {
        let ns = text.string as NSString
        var content = range
        while content.length > 0, [10, 13, 0x2029].contains(ns.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
        let para = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        let font = range.length > 0 ? text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont : nil
        if let para, !para.textLists.isEmpty, ListFormatting.markersInContent {
            let marker = ListFormatting.markerLength(in: ns, at: content.location, isList: true)
            content.location += marker; content.length = max(0, content.length - marker)
        }

        var pPr = ""
        let styleID: String? =
            switch TextStyle.detect(font: font, paragraph: para) {
            case .title: "Title"
            case .heading1: "Heading1"
            case .heading2: "Heading2"
            case .heading3: "Heading3"
            case .quote: "Quote"
            case .caption: "Caption"
            default: nil
            }
        if let styleID, para?.textLists.isEmpty ?? true { pPr += "<w:pStyle w:val=\"\(styleID)\"/>" }
        if let para {
            if let list = para.textLists.last {
                pPr +=
                    "<w:numPr><w:ilvl w:val=\"\(min(8, para.textLists.count - 1))\"/><w:numId w:val=\"\(numberingID(for: list))\"/></w:numPr>"
            }
            if Markdown.isRule(para, content: NSRange(location: content.location, length: content.length)) {
                pPr += "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BFBFC7\"/></w:pBdr>"
            }
            let before = Int(para.paragraphSpacingBefore * 20), after = Int(para.paragraphSpacing * 20)
            var spacing = "<w:spacing w:before=\"\(before)\" w:after=\"\(after)\""
            if para.lineHeightMultiple > 0 { spacing += " w:line=\"\(Int(para.lineHeightMultiple * 240))\" w:lineRule=\"auto\"" }
            pPr += spacing + "/>"
            let left = Int(para.headIndent * 20), first = Int((para.firstLineHeadIndent - para.headIndent) * 20)
            if left != 0 || first != 0 {
                pPr += "<w:ind w:left=\"\(left)\"" + (first < 0 ? " w:hanging=\"\(-first)\"" : " w:firstLine=\"\(first)\"") + "/>"
            }
            switch para.alignment {
            case .center: pPr += "<w:jc w:val=\"center\"/>"
            case .right: pPr += "<w:jc w:val=\"right\"/>"
            case .justified: pPr += "<w:jc w:val=\"both\"/>"
            default: break
            }
        }

        var runs = ""
        if content.length > 0 {
            text.enumerateAttributes(in: content) { attrs, run, _ in
                let piece = runXML(ns.substring(with: run), attrs: attrs)
                if let link = attrs[.link], let url = (link as? URL)?.absoluteString ?? (link as? String) {
                    let id = "rId\(relationships.count + 10)"
                    relationships.append((id, "hyperlink", url, true))
                    runs += "<w:hyperlink r:id=\"\(id)\">\(piece)</w:hyperlink>"
                } else {
                    runs += piece
                }
            }
        }
        return "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + runs + "</w:p>"
    }

    private mutating func runXML(_ string: String, attrs: [NSAttributedString.Key: Any]) -> String {
        if let attachment = attrs[.attachment] as? NSTextAttachment {
            return imageXML(attachment) ?? ""
        }
        var rPr = ""
        if let font = attrs[.font] as? NSFont {
            let family = Self.escape(font.familyName ?? TextStyle.family)
            rPr += "<w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\" w:cs=\"\(family)\"/>"
            if font.isBold { rPr += "<w:b/>" }
            if font.isItalic { rPr += "<w:i/>" }
        }
        if let u = attrs[.underlineStyle] as? Int, u != 0 {
            rPr += "<w:u w:val=\"\(u & NSUnderlineStyle.double.rawValue != 0 ? "double" : "single")\"/>"
        }
        if let s = attrs[.strikethroughStyle] as? Int, s != 0 { rPr += "<w:strike/>" }
        if let color = attrs[.foregroundColor] as? NSColor, let hex = Self.hex(color) { rPr += "<w:color w:val=\"\(hex)\"/>" }
        if let font = attrs[.font] as? NSFont { rPr += "<w:sz w:val=\"\(Int((font.pointSize * 2).rounded()))\"/>" }
        if let bg = attrs[.backgroundColor] as? NSColor, let hex = Self.hex(bg) {
            rPr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(hex)\"/>"
        }
        let superscript = (attrs[.superscript] as? Int) ?? 0
        let offset = (attrs[.baselineOffset] as? Double) ?? 0
        if superscript > 0 || offset > 0 { rPr += "<w:vertAlign w:val=\"superscript\"/>" }
        if superscript < 0 || offset < 0 { rPr += "<w:vertAlign w:val=\"subscript\"/>" }

        var body = ""
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { body += "<w:t xml:space=\"preserve\">\(Self.escape(buffer))</w:t>"; buffer = "" }
        }
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\t": flush(); body += "<w:tab/>"
            case "\u{2028}": flush(); body += "<w:br/>"
            case "\u{0C}": flush(); body += "<w:br w:type=\"page\"/>"
            case "\u{FFFC}": continue
            default: buffer.unicodeScalars.append(scalar)
            }
        }
        flush()
        return "<w:r>" + (rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>") + body + "</w:r>"
    }

    private mutating func imageXML(_ attachment: NSTextAttachment) -> String? {
        guard
            let image = attachment.image
                ?? (attachment.contents ?? attachment.fileWrapper?.regularFileContents).flatMap(NSImage.init(data:)),
            let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        drawingID += 1
        let name = "image\(drawingID).png"
        let id = "rIdImg\(drawingID)"
        media.append(.init(path: "word/media/\(name)", data: png))
        relationships.append((id, "image", "media/\(name)", false))
        let size = attachment.bounds.size == .zero ? image.size : attachment.bounds.size
        let cx = Int(size.width * 12700), cy = Int(size.height * 12700)
        return """
            <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
            <wp:docPr id="\(drawingID)" name="Picture \(drawingID)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:pic><pic:nvPicPr><pic:cNvPr id="\(drawingID)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
            """
    }

    private func sectionXML() -> String {
        let w = Int(page.paperSize.width * 20), h = Int(page.paperSize.height * 20)
        let m = page.margins
        return "<w:sectPr><w:pgSz w:w=\"\(w)\" w:h=\"\(h)\"/><w:pgMar w:top=\"\(Int(m.top * 20))\" w:right=\"\(Int(m.right * 20))\" "
            + "w:bottom=\"\(Int(m.bottom * 20))\" w:left=\"\(Int(m.left * 20))\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
    }

    // MARK: Numbering

    private mutating func numberingID(for list: NSTextList) -> Int {
        let key = ObjectIdentifier(list)
        if let existing = lists[key] { return existing.id }
        let id = lists.count + 1
        lists[key] = (id, list)
        return id
    }

    private func numberingXML() -> String {
        var abstract = ""
        var nums = ""
        for (id, list) in lists.values.sorted(by: { $0.id < $1.id }) {
            let (format, text): (String, String) =
                switch list.markerFormat {
                case .decimal: ("decimal", "%1.")
                case .lowercaseAlpha: ("lowerLetter", "%1.")
                case .uppercaseAlpha: ("upperLetter", "%1.")
                case .lowercaseRoman: ("lowerRoman", "%1.")
                case .uppercaseRoman: ("upperRoman", "%1.")
                case .box: ("bullet", "☐")
                case .check: ("bullet", "☑")
                case .hyphen: ("bullet", "–")
                case .circle: ("bullet", "◦")
                case .square: ("bullet", "▪")
                default: ("bullet", "•")
                }
            let levels = (0..<3).map { level in
                let levelText = format == "bullet" ? text : "%\(level + 1)."
                return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"\(max(1, list.startingItemNumber))\"/><w:numFmt w:val=\"\(format)\"/>"
                    + "<w:lvlText w:val=\"\(levelText)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (level + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }.joined()
            abstract += "<w:abstractNum w:abstractNumId=\"\(id)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels)</w:abstractNum>"
            nums += "<w:num w:numId=\"\(id)\"><w:abstractNumId w:val=\"\(id)\"/></w:num>"
        }
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(abstract)\(nums)</w:numbering>
            """
    }

    // MARK: Styles

    /// Named styles so Word's navigation pane and style gallery recognise Folio's
    /// headings. Runs also carry direct formatting, so readers that ignore styles
    /// (including the system's own) still show the right fonts.
    private static let stylesXML: String = {
        func style(_ id: String, _ name: String, size: Int, bold: Bool = false, italic: Bool = false, outline: Int? = nil) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>"
                + (outline.map { "<w:pPr><w:keepNext/><w:outlineLvl w:val=\"\($0)\"/></w:pPr>" } ?? "")
                + "<w:rPr>\(bold ? "<w:b/>" : "")\(italic ? "<w:i/>" : "")<w:sz w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        let family = TextStyle.family
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
            <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="\(family)" w:hAnsi="\(family)" w:cs="\(family)"/><w:sz w:val="24"/></w:rPr></w:rPrDefault></w:docDefaults>\
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
            \(style("Title", "Title", size: 52, bold: true))\
            \(style("Heading1", "heading 1", size: 40, bold: true, outline: 0))\
            \(style("Heading2", "heading 2", size: 32, bold: true, outline: 1))\
            \(style("Heading3", "heading 3", size: 26, bold: true, outline: 2))\
            \(style("Quote", "Quote", size: 24, italic: true))\
            \(style("Caption", "caption", size: 20))\
            </w:styles>
            """
    }()

    // MARK: Encoding helpers

    /// XML-escapes text and drops characters XML 1.0 can't contain.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if scalar.value < 0x20, scalar != "\t", scalar != "\n", scalar != "\r" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// "RRGGBB", or `nil` for colors that can't be expressed in sRGB or are transparent.
    static func hex(_ color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB), c.alphaComponent > 0.01 else { return nil }
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()),
            b = Int((c.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
