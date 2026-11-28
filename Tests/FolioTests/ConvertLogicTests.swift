import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import FolioConvert
import Testing

@testable import Folio

private let png = [
    Target(to: .png, fidelity: .lossless, losslessAvailable: true),
    Target(to: .jpeg, fidelity: .visuallyLossless, losslessAvailable: false),
    Target(to: .heic, fidelity: .visuallyLossless, losslessAvailable: false),
    Target(to: .tiff, fidelity: .lossless, losslessAvailable: true, drops: ["transparency"]),
]
private let heic = [
    Target(to: .jpeg, fidelity: .lossy, losslessAvailable: false),
    Target(to: .tiff, fidelity: .lossless, losslessAvailable: false, drops: ["depth map"]),
    Target(to: .png, fidelity: .lossless, losslessAvailable: true),
]

@Suite("Shared targets")
struct SharedTargetTests {
    @Test func keepsOnlyTargetsEveryFileHasInFirstFilesOrder() {
        #expect(SharedTargets.intersect([png, heic]).map(\.to) == [.png, .jpeg, .tiff])
        #expect(SharedTargets.intersect([png]).map(\.to) == png.map(\.to))
        #expect(SharedTargets.intersect([]).isEmpty)
        #expect(SharedTargets.intersect([png, []]).isEmpty)
    }

    @Test func sharedTargetIsAsGoodAsItsWeakestPair() throws {
        let shared = SharedTargets.intersect([png, heic])
        let jpeg = try #require(shared.first { $0.to == .jpeg })
        #expect(jpeg.fidelity == .lossy)
        let tiff = try #require(shared.first { $0.to == .tiff })
        #expect(tiff.losslessAvailable == false)
        #expect(tiff.drops == ["depth map", "transparency"])
        #expect(shared.first { $0.to == .png }?.losslessAvailable == true)
    }

    @Test func familyOfASelection() {
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.HEIC"), c = URL(fileURLWithPath: "/tmp/c.pdf")
        #expect(SharedTargets.family(of: [a, b]) == "image")
        #expect(SharedTargets.family(of: [a, c]) == "mixed")
    }
}

@Suite("Remembered choices")
struct ConvertChoiceTests {
    @Test func roundTripsPerFamily() throws {
        let defaults = try #require(UserDefaults(suiteName: "folio.tests.\(UUID().uuidString)"))
        let choice = ConvertChoice(target: .heic, quality: .small, maxMegabytes: 10, stripMetadata: true)
        choice.save(family: "image", defaults: defaults)
        #expect(ConvertChoice.load(family: "image", defaults: defaults) == choice)
        #expect(ConvertChoice.load(family: "video", defaults: defaults) == nil)
        #expect(choice.maxBytes == 10_000_000)
        #expect(ConvertChoice(maxMegabytes: 0).maxBytes == nil)
    }

    @Test func fitsTheRememberedChoiceToWhatTheSelectionOffers() {
        let shared = SharedTargets.intersect([png, heic])
        // Remembered HEIC isn't offered: fall back to the first target.
        #expect(ConvertChoice(target: .heic).fitted(to: shared).target == .png)
        // A preferred format from ⌘K wins over memory.
        #expect(ConvertChoice(target: .png).fitted(to: shared, preferring: .jpeg).target == .jpeg)
        // Lossless drops to balanced where the target can't be lossless.
        #expect(ConvertChoice(target: .jpeg, quality: .lossless).fitted(to: shared).quality == .balanced)
        #expect(ConvertChoice(target: .png, quality: .lossless).fitted(to: shared).quality == .lossless)
        #expect(ConvertChoice(target: .png).fitted(to: []).target == nil)
    }
}

@Suite("Result wording")
struct ConvertSummaryTests {
    @Test func sizesAndSavings() {
        #expect(ConvertSummary.sizes(18_900_000, 4_100_000) == "18.9 MB → 4.1 MB · \u{2212}78 %")
        #expect(ConvertSummary.change(1000, 1120) == "+12 %")
        #expect(ConvertSummary.change(1000, 1000) == "0 %")
        #expect(ConvertSummary.change(0, 10) == "0 %")
    }

    @Test func fidelityAndDuration() {
        #expect(ConvertSummary.fidelity(.lossless, verified: true) == "Lossless, verified")
        #expect(ConvertSummary.fidelity(.visuallyLossless, verified: false) == "Visually lossless")
        #expect(ConvertSummary.fidelity(.lossy, verified: false) == "Smaller, some loss")
        #expect(ConvertSummary.duration(420) == "0.4 s")
        #expect(ConvertSummary.duration(125_000) == "2 min 5 s")
    }

    @Test func totalsCountOnlyFilesThatWereWritten() {
        let out = URL(fileURLWithPath: "/tmp/x.heic")
        let rows = [
            ConvertRow(name: "a.heic", output: out, bytesIn: 10_000_000, bytesOut: 2_000_000, fidelity: .visuallyLossless, durationMs: 300),
            ConvertRow(name: "b.heic", output: out, bytesIn: 8_900_000, bytesOut: 2_100_000, fidelity: .lossy, durationMs: 400),
            ConvertRow(name: "c.png", bytesIn: 5_000_000, failed: true, message: "Broken"),
        ]
        #expect(ConvertSummary.totals(rows) == "18.9 MB → 4.1 MB · \u{2212}78 %")
        #expect(ConvertSummary.meta(rows) == "Smaller, some loss · 0.4 s")
        #expect(ConvertSummary.totals([rows[2]]) == nil)
    }
}

@Suite("Dock drops")
struct DockDropTests {
    @Test func optionConvertsEverythingElseOpens() {
        #expect(DockDrop.route([]) == .open)
        #expect(DockDrop.route(.option) == .convert)
        #expect(DockDrop.route([.option, .command]) == .convert)
        #expect(DockDrop.route([.capsLock, .shift]) == .open)
    }
}

@Suite("Finder Quick Actions")
struct ConvertServicesTests {
    @Test func servicesListConvertAndCompress() throws {
        let data = Data(ToolCatalog.servicesJSON().utf8)
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let byMessage = Dictionary(entries.map { ($0["NSMessage"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        let convert = try #require(byMessage["convertFiles"])
        let compress = try #require(byMessage["compressFiles"])
        #expect((convert["NSMenuItem"] as? [String: String])?["default"] == "Convert with Folio…")
        #expect((compress["NSMenuItem"] as? [String: String])?["default"] == "Compress with Folio")
        let types = try #require(convert["NSSendFileTypes"] as? [String])
        #expect(types.contains("public.png") && types.contains("com.adobe.pdf") && types.contains("public.movie"))
        #expect(Set(types).count == types.count)
        // The per-tool entries are still there.
        #expect(entries.contains { $0["NSMessage"] as? String == "runTool" })
    }
}

@Suite("Shelf history")
struct ConvertHistoryTests {
    @Test func keepsTheNewestFewWrittenFiles() {
        let history = ConvertHistory()
        let rows = (0..<7).map { ConvertRow(name: "\($0).png", output: URL(fileURLWithPath: "/tmp/\($0).png"), bytesIn: 10, bytesOut: 5) }
        history.add(rows + [ConvertRow(name: "failed.png", bytesIn: 1, failed: true)])
        #expect(history.rows.map(\.name) == ["6.png", "5.png", "4.png", "3.png", "2.png"])
        history.remove([URL(fileURLWithPath: "/tmp/6.png")])
        #expect(history.rows.first?.name == "5.png")
    }
}
