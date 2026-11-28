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
        #expect(Format(id: "NEF") == .raw)
        #expect(Format(id: "tar.gz") == .tgz)
        #expect(Format(id: "7z") == .sevenZip)
        #expect(Format(id: "3gp") == .threegp)
        #expect(Format(id: "yml") == .yaml)
        #expect(Format(id: "ndjson") == .jsonl)
        #expect(Format(id: "aac") == .aac)
    }

    @Test("Double extensions are detected and stripped from output names")
    func compoundExtensions() {
        let url = URL(filePath: "/tmp/Photos 2024.TAR.GZ")
        #expect(Format.detect(url) == .tgz)
        #expect(Format.stem(of: url) == "Photos 2024")
        #expect(Format.detect(URL(filePath: "/tmp/a.tar.xz")) == .txz)
        #expect(Format.detect(URL(filePath: "/tmp/a.gz")) == .gz)
        #expect(Format.stem(of: URL(filePath: "/tmp/a.b.png")) == "a.b")
    }

    @Test("Every format has exactly one converter, and asking for targets never crashes")
    func everyFormatHasAConverter() throws {
        for family in Format.Family.allCases {
            #expect(Engine.converters.count { $0.family == family } == 1, "\(family)")
        }
        for format in Format.allCases {
            let converter = try Engine.converter(for: format)
            #expect(converter.family == format.family)
            for target in converter.targets(from: format) { #expect(target.to != .raw, "RAW is read-only") }
        }
    }

    @Test("Formats without targets yet fail with UNSUPPORTED_PAIR, not a crash")
    func pendingFormatsFailCleanly() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "folio-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inputs = ["a.tar.gz", "b.mkv", "c.epub", "d.ttf", "e.srt", "f.obj", "g.yaml", "h.xls"].map { folder.appending(path: $0) }
        for input in inputs { try Data("x".utf8).write(to: input) }
        let report = await Engine.run(ConvertRequest(inputs: inputs, target: .zip))
        #expect(report.results.map { $0.error?.code } == Array(repeating: .unsupportedPair, count: inputs.count))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == inputs.count)
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
