import AppKit
import FolioCode
import FolioDocs
public import Foundation
import PDFKit

/// Documents conversions, built on the Cocoa text system and Folio's Markdown renderer.
///
/// Word, RTF and OpenDocument import and export run on any thread. The HTML importer
/// (WebKit-backed) and AppKit printing (PDF) need the main thread, so only those jobs hop.
public nonisolated enum DocumentFamilyConverter: FamilyConverter {
    public static let family: Format.Family = .document

    static let sources: [Format] = [.docx, .doc, .rtf, .odt, .html, .md, .txt]
    static let outputs: [Format] = [.pdf, .docx, .rtf, .odt, .html, .md, .txt]
    /// What the Cocoa text system doesn't read from Word and OpenDocument files.
    static let wordDrops = ["headers and footers", "footnotes", "comments", "tracked changes"]

    public static func targets(from source: Format) -> [Target] {
        guard sources.contains(source) else { return [] }
        return outputs.filter { $0 != source }.map { target(from: source, to: $0) }
    }

    static func target(from source: Format, to target: Format) -> Target {
        let lost: [String] =
            switch source {
            case .docx, .odt: wordDrops
            case .html: ["scripts", "remote images"]
            default: []
            }
        switch (source, target) {
        case (.txt, .md):
            return Target(to: target, fidelity: .lossless, losslessAvailable: true, notes: "Plain text is already valid Markdown.")
        case (.md, .txt):
            return Target(
                to: target, fidelity: .contentOnly, losslessAvailable: true, drops: ["Markdown formatting"],
                notes: "Quality lossless keeps the Markdown source unchanged.")
        case (_, .md):
            return Target(to: target, fidelity: .contentOnly, losslessAvailable: false, drops: ["page layout", "fonts", "colours"] + lost)
        case (_, .txt):
            return Target(to: target, fidelity: .contentOnly, losslessAvailable: false, drops: ["formatting", "images"] + lost)
        default:
            return Target(to: target, fidelity: .visuallyLossless, losslessAvailable: false, drops: lost)
        }
    }

    public static func convert(_ job: Job) async throws -> Outcome {
        let pair = target(from: job.source, to: job.target)
        // Text is already Markdown, and lossless Markdown → text means "keep the source".
        if (job.source, job.target) == (.txt, .md) || ((job.source, job.target) == (.md, .txt) && job.quality == .lossless) {
            try FileManager.default.copyItem(at: job.input, to: job.output)
            let same = job.verify ? try Data(contentsOf: job.input) == Data(contentsOf: job.output) : nil
            return Outcome(
                fidelity: .lossless, method: "copy",
                verification: same.map { Verification(passed: $0, checks: ["opens", $0 ? "bytes identical" : "bytes differ"]) })
        }

        let data = try readInput(job.input)
        let title = job.input.deletingPathExtension().lastPathComponent
        let (source, target) = (job.source, job.target)
        let produced = try await onMain(needsMain(source, target), app: target == .pdf) {
            try produce(data, from: source, to: target, title: title)
        }
        job.progress(0.8)
        try produced.data.write(to: job.output)

        var verification: Verification?
        if job.verify {
            let written = try Data(contentsOf: job.output)
            let text = try await onMain(target == .html) { try plainText(of: written, as: target) }
            verification = compare(produced.reference, text)
        }
        var details: [String: JSONValue] = [:]
        if let pages = produced.pages { details["pages"] = .int(Int64(pages)) }
        return Outcome(
            fidelity: pair.fidelity, method: target == .pdf ? "render" : "convert", details: details, dropped: pair.drops,
            warnings: produced.warnings, verification: verification)
    }

    public static func inspect(_ url: URL, format: Format) async throws -> [String: JSONValue] {
        let data = try readInput(url)
        return try await onMain(format == .html) {
            let (text, attributes) = try read(data, as: format)
            let string = text.string
            var meta: [String: JSONValue] = [
                "words": .int(Int64(string.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)),
                "characters": .int(Int64(string.count)),
                "has_tables": .bool(hasTables(text)),
                "has_images": .bool(hasAttachments(text)),
            ]
            if let title = (attributes[.title] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? markdownTitle(data, format) {
                meta["title"] = .string(title)
            }
            return meta
        }
    }

    public static func extract(_ url: URL, format: Format, as kind: ExtractKind, options: ExtractOptions) async throws -> String {
        let data = try readInput(url)
        if format == .md || format == .txt { return decode(data) }
        return try await onMain(format == .html) {
            let (text, _) = try read(data, as: format)
            return kind == .markdown ? Markdown.string(from: text) : plain(text)
        }
    }

    public static func resource(for job: Job) -> Resource { .cpu }

    // MARK: Producing

    struct Produced: Sendable {
        var data: Data
        /// The text the output should hold, for verification.
        var reference: String
        var pages: Int?
        var warnings: [String] = []
    }

    /// HTML import (WebKit) and printing run on the main thread; everything else on any thread.
    static func needsMain(_ source: Format, _ target: Format) -> Bool {
        source == .html || target == .pdf || (source == .md && [.html, .docx].contains(target))
    }

    /// Runs on the main actor when `main` (after `produce` and friends checked their thread needs).
    static func produce(_ data: Data, from source: Format, to target: Format, title: String) throws -> Produced {
        // Markdown to HTML, PDF and Word goes through Folio's own renderer, as the editor's exports do.
        if source == .md, [.html, .pdf, .docx].contains(target) {
            let markdown = decode(data)
            let rendered = HTMLPage.document(body: MarkdownRenderer.render(markdown), title: title)
            if target == .html {
                let text = try importHTML(Data(rendered.utf8))
                return Produced(data: Data(rendered.utf8), reference: plain(text))
            }
            // The HTML importer drops form controls, so task boxes become characters.
            let body = MarkdownRenderer.render(markdown)
                .replacingOccurrences(of: "<input type=\"checkbox\" disabled checked>", with: "☑")
                .replacingOccurrences(of: "<input type=\"checkbox\" disabled>", with: "☐")
            let text = try importHTML(Data(HTMLPage.document(body: body, title: title, appearance: .light).utf8))
            let reference = plain(text)
            if target == .pdf {
                let pdf = try MainActor.assumeIsolated { try PrintSupport.pdf(from: text, title: title) }
                return Produced(data: pdf, reference: reference, pages: pageCount(pdf))
            }
            let docx = try text.data(
                from: NSRange(location: 0, length: text.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML, .title: title])
            return Produced(data: docx, reference: reference)
        }

        let (text, attributes) = try read(data, as: source)
        let page = PageSetup(attributes: attributes)
        let reference = plain(text)
        if target == .pdf {
            let pdf = try MainActor.assumeIsolated { try PDFRenderer.pdf(text, page: page) }
            return Produced(data: pdf, reference: reference, pages: pageCount(pdf))
        }
        guard let format = DocFormat(rawValue: target.rawValue) else {
            throw ConvertError(.unsupportedPair, "Folio can't write \(target.title) documents.")
        }
        do {
            return Produced(data: try DocumentCodec.data(text, attributes: attributes, page: page, as: format), reference: reference)
        } catch {
            throw ConvertError(.internal, error.localizedDescription)
        }
    }

    /// Parses `data` as `format`. HTML has its remote resources removed first.
    static func read(_ data: Data, as format: Format) throws -> (text: NSMutableAttributedString, attributes: DocumentCodec.Attributes) {
        guard let docFormat = DocFormat(rawValue: format.rawValue) else {
            throw ConvertError(.unsupportedInput, "Folio can't read \(format.title) files as documents.")
        }
        do {
            return try DocumentCodec.read(format == .html ? Data(withoutRemoteResources(decode(data)).utf8) : data, as: docFormat)
        } catch {
            throw ConvertError(.corruptInput, error.localizedDescription)
        }
    }

    static func importHTML(_ html: Data) throws -> NSMutableAttributedString { try read(html, as: .html).text }

    // MARK: Network safety

    /// Tags whose attributes make the HTML importer (WebKit) fetch something.
    static let loadingTag = try! NSRegularExpression(
        pattern: #"<\s*(img|image|link|script|iframe|frame|embed|object|video|audio|source|track|input|base|body|table|td|th)\b[^>]*>"#,
        options: [.caseInsensitive])
    static let remoteAttribute = try! NSRegularExpression(
        pattern: #"\b(src|href|srcset|data|poster|background|lowsrc|dynsrc)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: [.caseInsensitive])
    static let remoteCSS = try! NSRegularExpression(
        pattern: #"(@import\s+)?url\(\s*['"]?\s*(?:https?:)?//[^)]*\)|@import\s+['"]\s*(?:https?:)?//[^'"]*['"]"#,
        options: [.caseInsensitive])

    /// The HTML with every `http(s)` and protocol-relative resource URL blanked, so importing
    /// or rendering it never touches the network. Links (`<a href>`) are kept: they aren't loaded.
    static func withoutRemoteResources(_ html: String) -> String {
        func isRemote(_ value: String) -> Bool {
            let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\n\r")).lowercased()
            // srcset lists several URLs; any remote one blanks the attribute.
            return v.hasPrefix("//") || v.hasPrefix("http:") || v.hasPrefix("https:") || v.contains(" http:") || v.contains(" https:")
                || v.contains(",http") || v.contains(", http") || v.contains(" //")
        }
        func replacing(
            _ regex: NSRegularExpression, in string: String, with transform: (NSTextCheckingResult, NSString) -> String
        ) -> String {
            let ns = string as NSString
            var out = ""
            var last = 0
            for match in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                out += transform(match, ns)
                last = match.range.location + match.range.length
            }
            return out + ns.substring(from: last)
        }
        let tagsDone = replacing(loadingTag, in: html) { match, ns in
            let tag = ns.substring(with: match.range)
            return replacing(remoteAttribute, in: tag) { attribute, tagNS in
                let name = tagNS.substring(with: attribute.range(at: 1))
                let value = tagNS.substring(with: attribute.range(at: 2))
                return isRemote(value) ? "\(name)=\"\"" : tagNS.substring(with: attribute.range)
            }
        }
        return replacing(remoteCSS, in: tagsDone) { _, _ in "none" }
    }

    // MARK: Verification

    static func plainText(of data: Data, as format: Format) throws -> String {
        switch format {
        case .pdf:
            guard let document = PDFDocument(data: data) else { throw ConvertError(.verificationFailed, "The PDF doesn't open.") }
            return document.string ?? ""
        case .md: return plain(Markdown.attributedString(from: decode(data)))
        case .txt: return decode(data)
        default: return plain(try read(data, as: format).text)
        }
    }

    /// Text identical once whitespace (which layout changes freely) is ignored.
    static func compare(_ expected: String, _ actual: String) -> Verification {
        let a = normalized(expected), b = normalized(actual)
        let passed = a == b
        return Verification(
            passed: passed, checks: ["opens", passed ? "text identical (ignoring whitespace)" : "text differs"],
            metrics: ["characters": Double(a.count), "output_characters": Double(b.count)])
    }

    static func normalized(_ s: String) -> String {
        // NFKC folds ligatures PDF text extraction can produce ("ﬁ" → "fi").
        String(
            String.UnicodeScalarView(
                s.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
                    !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{FFFC}" && $0 != "\u{200B}"
                }))
    }

    // MARK: Helpers

    /// Plain text with list markers spelled out, as Folio's .txt export writes it.
    static func plain(_ text: NSAttributedString) -> String {
        (try? DocumentCodec.data(text, page: PageSetup(), as: .txt)).map(decode) ?? text.string
    }

    static func hasTables(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, style.textBlocks.contains(where: { $0 is NSTextTableBlock }) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    static func hasAttachments(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// A Markdown file's first `# Heading`.
    static func markdownTitle(_ data: Data, _ format: Format) -> String? {
        guard format == .md else { return nil }
        return decode(data).split(separator: "\n", omittingEmptySubsequences: true).lazy
            .first { $0.hasPrefix("# ") }
            .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
    }

    static func pageCount(_ pdf: Data) -> Int? {
        CGDataProvider(data: pdf as CFData).flatMap(CGPDFDocument.init)?.numberOfPages
    }

    static func readInput(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw ConvertError(.notFound, "Couldn't read \(url.lastPathComponent).")
        }
    }

    /// UTF-8 when valid, otherwise Windows Latin 1 (what most legacy text files are).
    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Runs `body` on the main actor when `main` is set. `app` makes sure an `NSApplication`
    /// exists first: AppKit printing expects one, and the `folio` CLI never creates it.
    static func onMain<T: Sendable>(_ main: Bool, app: Bool = false, _ body: @Sendable () throws -> T) async throws -> T {
        guard main else { return try body() }
        return try await MainActor.run {
            if app, NSApp == nil { NSApplication.shared.setActivationPolicy(.prohibited) }
            return try body()
        }
    }
}
