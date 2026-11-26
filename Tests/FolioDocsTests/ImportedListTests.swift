import AppKit
import Testing

@testable import FolioDocs

/// Lists written by other apps often start flush left (their markers used to be text),
/// which leaves Folio nowhere to draw the marker on macOS 26+. Reading must fix that.
@Suite("Imported lists")
struct ImportedListTests {
    private func flushList() throws -> Data {
        let style = NSMutableParagraphStyle()
        style.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        style.headIndent = 36
        style.firstLineHeadIndent = 0
        let text = NSAttributedString(string: "First item\nSecond item\n", attributes: [.paragraphStyle: style])
        return try text.data(
            from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    @Test func importedListItemsGetRoomForTheirMarker() throws {
        let (text, _) = try DocumentCodec.read(try flushList(), as: .rtf)
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(!style.textLists.isEmpty)
        if !ListFormatting.markersInContent {
            #expect(style.firstLineHeadIndent >= ListFormatting.indent)
            #expect(style.firstLineHeadIndent == style.headIndent)
        }
    }

    @Test func nonListParagraphsAreUntouched() throws {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = 20
        let source = NSAttributedString(string: "Plain\n", attributes: [.paragraphStyle: style])
        let data = try source.data(
            from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let (text, _) = try DocumentCodec.read(data, as: .rtf)
        let read = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(read.firstLineHeadIndent == 0)
    }
}
