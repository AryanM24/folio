import AppKit

@testable import FolioDocs

/// Builds documents for tests (and, with `FOLIO_SAMPLES_DIR`, sample files for
/// snapshots): a title, headings, formatted body text, lists, a table and a page break.
enum Fixtures {
    static func paragraph(_ text: String, _ style: TextStyle) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: style.attributes())
    }

    static func list(_ items: [String], _ kind: ListKind) -> NSAttributedString {
        let body = NSMutableAttributedString()
        for item in items { body.append(paragraph(item, .body)) }
        return ListFormatting.toggle(kind, in: body)
    }

    static func table(_ rows: [[String]]) -> NSAttributedString {
        TableModel(cells: rows.map { $0.map { paragraph($0, .body) } }).render()
    }

    static func richDocument() -> NSMutableAttributedString {
        let doc = NSMutableAttributedString()
        doc.append(paragraph("Quarterly Report", .title))
        doc.append(paragraph("Summary", .heading1))
        let body = NSMutableAttributedString(string: "Revenue grew ", attributes: TextStyle.body.attributes())
        var bold = TextStyle.body.attributes()
        bold[.font] = TextStyle.body.font.adding(.bold)
        body.append(NSAttributedString(string: "18%", attributes: bold))
        var italic = TextStyle.body.attributes()
        italic[.font] = TextStyle.body.font.adding(.italic)
        body.append(NSAttributedString(string: " this quarter", attributes: italic))
        var link = TextStyle.body.attributes()
        link[.link] = URL(string: "https://example.com")
        body.append(NSAttributedString(string: " (details)", attributes: link))
        body.append(NSAttributedString(string: ".\n", attributes: TextStyle.body.attributes()))
        doc.append(body)
        doc.append(paragraph("Highlights", .heading2))
        doc.append(list(["New customers", "Lower churn", "Two launches"], .bullet))
        doc.append(paragraph("Next steps", .heading2))
        doc.append(list(["Hire", "Ship", "Measure"], .numbered))
        doc.append(list(["Draft budget"], .checklist))
        doc.append(paragraph("Numbers", .heading3))
        doc.append(table([["Region", "Q1", "Q2"], ["North", "120", "140"], ["South", "90", "115"]]))
        doc.append(paragraph("A quiet closing thought.", .quote))
        doc.append(NSAttributedString(string: "Appendix\u{0C}\n", attributes: TextStyle.body.attributes()))
        doc.append(paragraph("let total = q1 + q2", .code))
        return doc
    }

    /// About `pages` printed pages of headed sections.
    static func longDocument(pages: Int) -> NSMutableAttributedString {
        let doc = NSMutableAttributedString()
        let sentence = "The quick brown fox jumps over the lazy dog while the committee reviews the quarterly plan in detail. "
        let body = String(repeating: sentence, count: 6)
        for section in 1...(pages * 2) {
            if section % 4 == 1 { doc.append(paragraph("Chapter \(section / 4 + 1)", .heading1)) }
            doc.append(paragraph("Section \(section)", .heading2))
            doc.append(paragraph(body, .body))
            doc.append(paragraph(body, .body))
        }
        return doc
    }
}
