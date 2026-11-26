import Testing
@testable import FolioMedia

@Test func documentStartsEmpty() {
    #expect(MediaDocument().data.isEmpty)
}
