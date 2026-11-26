import AppKit
import FolioKit
import UniformTypeIdentifiers

/// Inserting links, images, tables, rules and page breaks, and editing table structure.
extension DocumentEditorController {

    // MARK: Links

    /// Links the selected text, or inserts the link's own text when nothing is selected.
    func insertLink(_ url: URL) {
        guard let textView else { return }
        if textView.selectedRange().length > 0 {
            changeCharacters("Add Link") { $0[.link] = url }
        } else {
            var attrs = textView.typingAttributes
            attrs[.link] = url
            insert(NSAttributedString(string: url.absoluteString, attributes: attrs), actionName: "Add Link")
        }
    }

    /// Removes the link under the caret or in the selection.
    func removeLink() {
        guard let textView, let storage, storage.length > 0 else { return }
        var range = textView.selectedRange()
        if range.length == 0 {
            var effective = NSRange()
            let at = min(range.location, storage.length - 1)
            guard
                storage.attribute(.link, at: at, longestEffectiveRange: &effective, in: NSRange(location: 0, length: storage.length)) != nil
            else { return }
            range = effective
            textView.setSelectedRange(range)
        }
        changeCharacters("Remove Link") { $0[.link] = nil }
    }

    // MARK: Images

    /// Lets the user pick images and inserts them, scaled to fit the text width.
    func chooseImages() {
        Task {
            let urls = await Exporter.pick(types: [.image], multiple: true, window: textView?.window)
            insertImages(urls)
        }
    }

    func insertImages(_ urls: [URL]) {
        let out = NSMutableAttributedString()
        for url in urls {
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
                Alert.show(
                    FolioError("“\(url.lastPathComponent)” isn't an image Folio can read."), title: "Couldn't insert image",
                    window: textView?.window)
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension) ?? .png
            let attachment = NSTextAttachment(data: data, ofType: type.identifier)
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: fittedSize(image.size, fraction: 1))
            out.append(NSAttributedString(attachment: attachment))
        }
        guard out.length > 0 else { return }
        if let typing = textView?.typingAttributes {
            out.addAttributes(typing.filter { $0.key == .paragraphStyle }, range: NSRange(location: 0, length: out.length))
        }
        insert(out, actionName: urls.count == 1 ? "Insert Image" : "Insert Images")
    }

    /// Resizes the selected image to a fraction of the text width (`nil`: natural size).
    func setImageWidth(_ fraction: CGFloat?) {
        guard let textView, let storage else { return }
        let range = textView.selectedRange()
        guard range.length == 1, let old = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
            let image = old.image ?? old.contents.flatMap(NSImage.init(data:))
                ?? old.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
        else { return }
        let resized = NSTextAttachment(data: old.contents ?? old.fileWrapper?.regularFileContents, ofType: old.fileType)
        resized.image = image
        resized.bounds = CGRect(
            origin: .zero, size: fraction.map { fittedSize(image.size, fraction: $0, upscale: true) } ?? fittedSize(image.size, fraction: 1)
        )
        changeCharacters("Resize Image") { $0[.attachment] = resized }
    }

    /// `size` scaled to `fraction` of the text width; never wider than the text.
    private func fittedSize(_ size: CGSize, fraction: CGFloat, upscale: Bool = false) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
        let available = (textView?.textContainer?.size.width ?? 468) * fraction
        let scale = upscale ? available / size.width : min(1, available / size.width)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    // MARK: Tables

    /// Inserts an empty table on its own lines and puts the caret in the first cell.
    func insertTable(rows: Int, columns: Int) {
        guard let textView, let storage else { return }
        let caret = textView.selectedRange()
        let ns = storage.string as NSString
        var attrs = textView.typingAttributes
        attrs[.paragraphStyle] = nil
        let table = TableModel(rows: rows, columns: columns, attributes: attrs).render()
        let out = NSMutableAttributedString()
        // Start on a fresh line unless the caret is already at the start of an empty one.
        let paragraph = ns.paragraphRange(for: NSRange(location: caret.location, length: 0))
        let atLineStart = caret.location == paragraph.location
        let lineIsEmpty = (paragraph.length == 0) || ns.substring(with: paragraph).trimmingCharacters(in: .newlines).isEmpty
        if !(atLineStart && lineIsEmpty) && caret.location > 0 {
            out.append(NSAttributedString(string: "\n", attributes: textView.typingAttributes))
        }
        let tableStart = caret.location + out.length
        out.append(table)
        // Something to type into after the table.
        if NSMaxRange(caret) >= storage.length || !atLineStart {
            out.append(NSAttributedString(string: "\n", attributes: TextStyle.body.attributes()))
        }
        let replaceRange = atLineStart && lineIsEmpty && paragraph.length > 0 ? paragraph : caret
        replace(replaceRange, with: out, actionName: "Insert Table", select: NSRange(location: tableStart, length: 0))
    }

    enum TableEdit { case rowAbove, rowBelow, columnLeft, columnRight, deleteRow, deleteColumn, deleteTable }

    /// Adds or removes a row or column of the table at the caret.
    func editTable(_ edit: TableEdit) {
        guard let textView, let storage else { return }
        let caret = textView.selectedRange().location
        guard var (model, range) = TableModel.read(from: storage, at: caret).map({ ($0.model, $0.range) }),
            let cell = TableModel.cell(in: storage, at: caret)
        else { return }
        if edit == .deleteTable {
            replace(range, with: NSAttributedString(), actionName: "Delete Table")
            return
        }
        var target = cell
        let name: String
        switch edit {
        case .rowAbove: model.insertRow(at: cell.row); name = "Add Row"
        case .rowBelow: model.insertRow(at: cell.row + 1); target.row += 1; name = "Add Row"
        case .columnLeft: model.insertColumn(at: cell.column); name = "Add Column"
        case .columnRight: model.insertColumn(at: cell.column + 1); target.column += 1; name = "Add Column"
        case .deleteRow:
            guard model.rowCount > 1 else { return editTable(.deleteTable) }
            model.deleteRow(at: cell.row); target.row = min(cell.row, model.rowCount - 1); name = "Delete Row"
        case .deleteColumn:
            guard model.columnCount > 1 else { return editTable(.deleteTable) }
            model.deleteColumn(at: cell.column); target.column = min(cell.column, model.columnCount - 1); name = "Delete Column"
        case .deleteTable: return
        }
        let rendered = model.render()
        let offset = model.offset(ofRow: target.row, column: target.column)
        replace(range, with: rendered, actionName: name, select: NSRange(location: range.location + offset, length: 0))
    }

    // MARK: Breaks and rules

    /// Inserts a horizontal rule as its own paragraph after the caret's paragraph.
    func insertHorizontalRule() {
        guard let textView, let storage else { return }
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: textView.selectedRange().location, length: 0))
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(NSColor(srgbRed: 0.75, green: 0.75, blue: 0.78, alpha: 1), for: .maxY)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        let out = NSMutableAttributedString()
        let needsNewline = paragraph.length == 0 || !ns.substring(with: paragraph).hasSuffix("\n")
        if needsNewline && paragraph.location + paragraph.length > 0 {
            out.append(NSAttributedString(string: "\n", attributes: textView.typingAttributes))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: TextStyle.body.font.withSize(4), .paragraphStyle: style]))
        let insertAt = NSMaxRange(paragraph)
        if insertAt >= storage.length {
            out.append(NSAttributedString(string: "\n", attributes: TextStyle.body.attributes()))
        }
        replace(
            NSRange(location: insertAt, length: 0), with: out, actionName: "Insert Horizontal Rule",
            select: NSRange(location: insertAt + out.length - (insertAt >= storage.length ? 1 : 0), length: 0))
    }

    /// Inserts a page break: what follows starts on a new page when printed.
    func insertPageBreak() {
        guard let textView else { return }
        insert(NSAttributedString(string: "\u{0C}", attributes: textView.typingAttributes), actionName: "Insert Page Break")
    }
}
