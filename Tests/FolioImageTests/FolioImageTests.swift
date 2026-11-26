import Testing
@testable import FolioImage

@Test func documentStartsEmpty() {
    #expect(ImageDocument().data.isEmpty)
}
