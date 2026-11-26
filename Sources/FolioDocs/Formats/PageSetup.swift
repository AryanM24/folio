public import AppKit
public import Foundation

/// Paper size and margins of a document, in points.
///
/// Stored in the file's own document attributes (`PaperSize`, `LeftMargin`, …) so
/// Word, Pages and TextEdit see the same page Folio shows. Everything that paginates
/// (the editor's paper column, Print, PDF export, the page estimate) reads it from here.
public nonisolated struct PageSetup: Equatable, Sendable {
    /// The two paper sizes the toolbar offers. Others are kept as `.custom`.
    public enum Paper: String, CaseIterable, Sendable {
        case letter, a4, custom
        public var title: String {
            switch self {
            case .letter: "US Letter"
            case .a4: "A4"
            case .custom: "Custom"
            }
        }
        public var size: CGSize? {
            switch self {
            case .letter: CGSize(width: 612, height: 792)
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .custom: nil
            }
        }
    }

    public var paperSize: CGSize
    public var margins: NSEdgeInsets

    public init(
        paperSize: CGSize = Paper.letter.size ?? .zero, margins: NSEdgeInsets = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
    ) {
        self.paperSize = paperSize
        self.margins = margins
    }

    /// The named paper this size matches, within a point (A4 is fractional).
    public var paper: Paper {
        Paper.allCases.first { p in
            guard let s = p.size else { return false }
            return abs(s.width - paperSize.width) < 1 && abs(s.height - paperSize.height) < 1
        } ?? .custom
    }

    /// Area inside the margins, where text goes.
    public var contentSize: CGSize {
        CGSize(
            width: max(72, paperSize.width - margins.left - margins.right),
            height: max(72, paperSize.height - margins.top - margins.bottom))
    }

    /// Reads paper and margins from a file's document attributes, falling back to
    /// US Letter with 1-inch margins for anything missing or nonsensical.
    public init(attributes: [NSAttributedString.DocumentAttributeKey: Any]) {
        self.init()
        if let size = attributes[.paperSize] as? CGSize ?? (attributes[.paperSize] as? NSValue)?.sizeValue,
            size.width > 144, size.height > 144
        {
            paperSize = size
        }
        func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat? {
            guard let value = (attributes[key] as? NSNumber)?.doubleValue, value >= 0, value < 288 else { return nil }
            return CGFloat(value)
        }
        margins = NSEdgeInsets(
            top: margin(.topMargin) ?? 72,
            left: margin(.leftMargin) ?? 72,
            bottom: margin(.bottomMargin) ?? 72,
            right: margin(.rightMargin) ?? 72
        )
    }

    /// The same values as document attributes, ready to merge into a write.
    public var attributes: [NSAttributedString.DocumentAttributeKey: Any] {
        [
            .paperSize: NSValue(size: paperSize),
            .topMargin: margins.top, .leftMargin: margins.left,
            .bottomMargin: margins.bottom, .rightMargin: margins.right,
        ]
    }

    /// Switch paper, keeping margins.
    public func with(paper: Paper) -> PageSetup {
        var copy = self
        if let size = paper.size { copy.paperSize = size }
        return copy
    }

    public static func == (a: PageSetup, b: PageSetup) -> Bool {
        a.paperSize == b.paperSize && a.margins.top == b.margins.top && a.margins.left == b.margins.left
            && a.margins.bottom == b.margins.bottom && a.margins.right == b.margins.right
    }
}
