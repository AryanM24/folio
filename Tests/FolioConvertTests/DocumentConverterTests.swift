import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import Testing

@testable import FolioConvert

/// A fresh folder per test, so parallel tests never see each other's outputs.
func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "folio-convert-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Runs one conversion through the engine and returns its only result.
func convert(_ input: URL, to target: Format, quality: Quality = .balanced, verify: Bool = true, into folder: URL) async -> ConvertResult {
    let request = ConvertRequest(inputs: [input], target: target, quality: quality, outputDirectory: folder, verify: verify)
    return await Engine.run(request).results[0]
}

/// A small formatted Word document: heading, bold run, list-free body text.
func writeDocx(to url: URL, paragraphs: Int = 3) throws {
    let doc = NSMutableAttributedString()
    doc.append(NSAttributedString(string: "Quarterly report\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
    for i in 1...paragraphs {
        doc.append(
            NSAttributedString(
                string: "Paragraph \(i): the quick brown fox jumps over the lazy dog, with numbers 12345.\n",
                attributes: [.font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)]))
    }
    let data = try doc.data(
        from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    try data.write(to: url)
}

/// A loopback TCP listener that records whether anything connected to it.
final class Listener {
    let fd: Int32
    let port: UInt16

    init() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        listen(fd, 16)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: addr.sin_port)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Connections waiting in the backlog (each one a fetch attempt).
    func connections() -> Int {
        var n = 0
        while case let client = accept(fd, nil, nil), client >= 0 {
            close(client)
            n += 1
        }
        return n
    }

    deinit { close(fd) }
}

@Suite("Document conversions", .timeLimit(.minutes(1)))
struct DocumentConverterTests {
    @Test("Lossless is offered only between text and Markdown")
    func losslessPairs() {
        for source in DocumentFamilyConverter.sources {
            for target in DocumentFamilyConverter.targets(from: source) where target.losslessAvailable {
                #expect([(Format.txt, Format.md), (.md, .txt)].contains { $0 == (source, target.to) })
            }
        }
        #expect(!DocumentFamilyConverter.targets(from: .md).contains { $0.to == .md })
        let docxToRTF = DocumentFamilyConverter.target(from: .docx, to: .rtf)
        #expect(docxToRTF.fidelity == .visuallyLossless)
        #expect(docxToRTF.drops.contains("tracked changes"))
        #expect(DocumentFamilyConverter.target(from: .docx, to: .md).fidelity == .contentOnly)
    }

    @Test("docx → PDF from a background task, verified")
    func docxToPDFInBackground() async throws {
        let folder = try scratchFolder()
        let input = folder.appending(path: "report.docx")
        try writeDocx(to: input, paragraphs: 40)
        let result = await Task.detached { await convert(input, to: .pdf, into: folder) }.value
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.fidelity == .visuallyLossless)
        #expect(result.verification?.passed == true)
        #expect((result.details["pages"]).map { $0 != .int(0) } == true)
        let pdf = try Data(contentsOf: URL(fileURLWithPath: try #require(result.output)))
        #expect(pdf.starts(with: Array("%PDF".utf8)))
    }

    @Test("docx → Markdown → text, each step verified")
    func docxToMarkdownToText() async throws {
        let folder = try scratchFolder()
        let input = folder.appending(path: "notes.docx")
        try writeDocx(to: input)
        let md = await convert(input, to: .md, into: folder)
        #expect(md.status == .ok, "\(String(describing: md.error))")
        #expect(md.fidelity == .contentOnly)
        #expect(md.dropped.contains("page layout"))
        #expect(md.verification?.passed == true)
        let mdURL = URL(fileURLWithPath: try #require(md.output))
        #expect(try String(contentsOf: mdURL, encoding: .utf8).contains("quick brown fox"))

        let txt = await convert(mdURL, to: .txt, into: folder)
        #expect(txt.status == .ok)
        #expect(txt.verification?.passed == true)
        let text = try String(contentsOf: URL(fileURLWithPath: try #require(txt.output)), encoding: .utf8)
        #expect(text.contains("Paragraph 3: the quick brown fox"))
        #expect(!text.contains("**"))
    }

    @Test("Text ↔ Markdown lossless is a verified copy")
    func textMarkdownLossless() async throws {
        let folder = try scratchFolder()
        let input = folder.appending(path: "plain.txt")
        try Data("A *literal* line\n".utf8).write(to: input)
        let result = await convert(input, to: .md, quality: .lossless, into: folder)
        #expect(result.status == .ok)
        #expect(result.fidelity == .lossless)
        #expect(result.verification?.checks.contains("bytes identical") == true)
        // Lossless docx → rtf isn't possible, and the engine says so rather than degrading.
        let docx = folder.appending(path: "a.docx")
        try writeDocx(to: docx)
        #expect(await convert(docx, to: .rtf, quality: .lossless, into: folder).error?.code == .losslessUnavailable)
    }

    @Test("Markdown → HTML carries no network references")
    func markdownToHTML() async throws {
        let folder = try scratchFolder()
        let input = folder.appending(path: "readme.md")
        try Data("# Hello\n\nSome **bold** text.\n\n![logo](https://example.com/logo.png)\n".utf8).write(to: input)
        let result = await convert(input, to: .html, into: folder)
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.verification?.passed == true)
        let html = try String(contentsOf: URL(fileURLWithPath: try #require(result.output)), encoding: .utf8)
        #expect(html.contains("<strong>bold</strong>"))
        // The page forbids remote loads, and Folio adds no scripts, stylesheets or fonts of its own.
        #expect(html.contains("default-src 'none'"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<link"))
    }

    @Test("Remote resources are stripped before HTML is imported")
    func remoteResourcesStripped() {
        let html = """
            <img src="https://tracker.example/p.gif"><img src='//cdn.example/x.png' alt="x">
            <link rel="stylesheet" href="http://example.com/a.css"><script src=https://e.com/a.js></script>
            <img srcset="a.png 1x, https://e.com/b.png 2x"><iframe src="https://e.com"></iframe>
            <style>@import url(https://e.com/f.css); body { background: url('http://e.com/bg.png') }</style>
            <a href="https://example.com">a link</a><img src="local.png">
            """
        let safe = DocumentFamilyConverter.withoutRemoteResources(html)
        #expect(!safe.contains("tracker.example"))
        #expect(!safe.contains("cdn.example"))
        #expect(!safe.contains("e.com/"))
        #expect(!safe.contains("http://example.com/a.css"))
        #expect(safe.contains("<a href=\"https://example.com\">"))  // links aren't fetched
        #expect(safe.contains("src=\"local.png\""))
    }

    @Test(
        "Encoded and obfuscated resource URLs are blanked too",
        arguments: [
            #"<img src="&#104;ttps://evil.example/x.png">"#,
            #"<img src="ht&#x09;tp://evil.example/x.png">"#,
            #"<img src="https&colon;//evil.example/x.png">"#,
            #"<img src="  //evil.example/x.png">"#,
            #"<img src="javascript:fetch('//evil.example')">"#,
            #"<img srcset="a.png 1x, https://evil.example/x.png 2x">"#,
            #"<p style="background: u\72l(https://evil.example/x.png)">x</p>"#,
            #"<style>@import 'https://evil.example/a.css';</style>"#,
            #"<style>p { background: url(&quot;https://evil.example/x.png&quot;) }</style>"#,
            #"<style>p { background: image-set("https://evil.example/x.png" 1x) }</style>"#,
            #"<p style=background:url(https://evil.example/x.png)>x</p>"#,
        ])
    func obfuscatedURLs(html: String) {
        #expect(!DocumentFamilyConverter.withoutRemoteResources(html).contains("evil.example"))
    }

    @Test("Relative, fragment and data URLs survive")
    func safeURLsKept() {
        let html = #"<img src="images/a.png"><img src="data:image/png;base64,AAAA"><style>p { background: url(bg.png) }</style>"#
        let safe = DocumentFamilyConverter.withoutRemoteResources(html)
        #expect(safe.contains("images/a.png"))
        #expect(safe.contains("data:image/png;base64,AAAA"))
        #expect(safe.contains("url(bg.png)"))
    }

    @Test("Converting HTML or Markdown never fetches a remote image")
    func noFetch() async throws {
        let listener = Listener()
        let folder = try scratchFolder()
        let url = "http://127.0.0.1:\(listener.port)/pixel.png"
        let html = folder.appending(path: "page.html")
        try Data("<html><body><p>Hello there</p><img src=\"\(url)\"><link rel=stylesheet href=\"\(url)\"></body></html>".utf8)
            .write(to: html)
        let md = folder.appending(path: "page.md")
        try Data("Hello there\n\n![pixel](\(url))\n".utf8).write(to: md)

        let fromHTML = await convert(html, to: .docx, into: folder)
        #expect(fromHTML.status == .ok, "\(String(describing: fromHTML.error))")
        let fromMarkdown = await convert(md, to: .pdf, into: folder)
        #expect(fromMarkdown.status == .ok, "\(String(describing: fromMarkdown.error))")
        try await Task.sleep(for: .milliseconds(200))
        #expect(listener.connections() == 0)
    }

    @Test("Inspect and extract a Word document")
    func inspectAndExtract() async throws {
        let folder = try scratchFolder()
        let input = folder.appending(path: "info.docx")
        try writeDocx(to: input)
        let info = await Engine.inspect(input)
        #expect(info.error == nil)
        #expect(info.meta["has_tables"] == .bool(false))
        if case .int(let words) = info.meta["words"] { #expect(words > 30) } else { Issue.record("no word count") }
        #expect(info.targets.contains { $0.to == .pdf })
        let markdown = try await Engine.extract(input, as: .markdown)
        #expect(markdown.contains("quick brown fox"))
        let text = try await Engine.extract(input, as: .text)
        #expect(text.contains("Quarterly report"))
    }
}
