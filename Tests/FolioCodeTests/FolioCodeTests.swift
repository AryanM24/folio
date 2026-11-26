import Testing
@testable import FolioCode

@Test func documentStartsEmpty() {
    #expect(CodeDocument().data.isEmpty)
}
