import Testing

@testable import FolioAgent

@Suite("CLI")
struct CLITests {
    @Test("Unknown commands are usage errors")
    func unknown() async {
        #expect(await CLI.main(["frobnicate"]) == 2)
    }
}
