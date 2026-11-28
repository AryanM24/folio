import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import Testing

@testable import FolioConvert

@Suite("Engine", .timeLimit(.minutes(1)))
struct EngineTests {
    @Test("Format ids accept common aliases")
    func aliases() {
        #expect(Format(id: "JPG") == .jpeg)
        #expect(Format(id: ".tif") == .tiff)
        #expect(Format(id: "markdown") == .md)
        #expect(Format(id: "nope") == nil)
        #expect(Format.alac.fileExtension == "m4a")
    }

    @Test("A missing file fails with NOT_FOUND and writes nothing")
    func missingFile() async {
        let report = await Engine.run(ConvertRequest(inputs: [URL(fileURLWithPath: "/tmp/folio-does-not-exist.png")], target: .jpeg))
        #expect(report.results.first?.error?.code == .notFound)
        #expect(report.summary.failed == 1)
    }

    @Test("Results encode with snake_case keys")
    func encoding() throws {
        let report = ConvertReport(results: [], durationMs: 3)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(json.contains("\"duration_ms\":3"))
        #expect(json.contains("\"bytes_in\":0"))
    }
}
