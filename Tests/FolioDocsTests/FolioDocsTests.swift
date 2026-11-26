import Testing
@testable import FolioDocs

@Test func documentStartsEmpty() {
    #expect(RichTextDocument().data.isEmpty)
}
