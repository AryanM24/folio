import Foundation
import ZIPFoundation

/// A streaming XML reader: calls back on each element start and end.
///
/// Spreadsheet parts can be tens of megabytes, so we never build a tree. Namespace
/// prefixes are stripped from element and attribute names ("table:table-cell" →
/// "table-cell"), which is unambiguous for the parts we read.
nonisolated final class XMLScanner: NSObject, XMLParserDelegate {
    typealias Start = (_ name: String, _ attributes: [String: String]) -> Void
    /// `text` is the character data directly inside the element.
    typealias End = (_ name: String, _ text: String) -> Void

    private let onStart: Start
    private let onEnd: End
    private let onCharacters: ((String) -> Void)?
    private var textStack: [String] = []

    private init(start: @escaping Start, end: @escaping End, characters: ((String) -> Void)?) {
        onStart = start
        onEnd = end
        onCharacters = characters
    }

    /// - Parameter characters: optional, receives character data in document order
    ///   (for mixed content such as ODS paragraphs with spans).
    static func scan(
        _ data: Data, start: @escaping Start, end: @escaping End = { _, _ in },
        characters: ((String) -> Void)? = nil
    ) throws(FolioSheetsError) {
        let scanner = XMLScanner(start: start, end: end, characters: characters)
        let parser = XMLParser(data: data)
        parser.delegate = scanner
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw .unreadableFile("Part of the file is damaged (\(parser.parserError?.localizedDescription ?? "invalid XML")).")
        }
    }

    private static func local(_ name: String) -> String {
        guard let i = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: i)...])
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        var attrs: [String: String] = [:]
        for (k, v) in attributes { attrs[XMLScanner.local(k)] = v }
        // Keep the r:id style attribute reachable under its prefixed name too.
        for (k, v) in attributes where k.hasPrefix("r:") { attrs[k] = v }
        textStack.append("")
        onStart(XMLScanner.local(elementName), attrs)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !textStack.isEmpty { textStack[textStack.count - 1] += string }
        onCharacters?(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = textStack.popLast() ?? ""
        onEnd(XMLScanner.local(elementName), text)
    }
}

/// Builds XML text with escaping. Strips characters XML 1.0 can't carry.
nonisolated enum XMLText {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            default:
                if u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
}

/// Reading and writing the zip containers behind XLSX and ODS.
nonisolated enum ZipPackage {
    /// Largest part we'll inflate, so a malicious "zip bomb" can't exhaust memory.
    static let maxPartSize: Int64 = 1 << 30

    static func open(_ data: Data) throws(FolioSheetsError) -> Archive {
        do {
            return try Archive(data: data, accessMode: .read)
        } catch {
            throw .unreadableFile("This file isn't a valid spreadsheet package.")
        }
    }

    static func read(_ archive: Archive, _ path: String) throws(FolioSheetsError) -> Data? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let entry = archive[trimmed] else { return nil }
        guard Int64(entry.uncompressedSize) <= maxPartSize else { throw .unreadableFile("Part of this file is too large to open.") }
        var out = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { out.append($0) }
        } catch {
            throw .unreadableFile("Part of the file is damaged and couldn't be decompressed.")
        }
        return out
    }

    /// Writes parts in order. `stored` parts are not compressed (ODS needs "mimetype" first and stored).
    static func write(_ parts: [(path: String, data: Data, stored: Bool)]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for part in parts {
            let data = part.data
            try archive.addEntry(
                with: part.path, type: .file, uncompressedSize: Int64(data.count),
                compressionMethod: part.stored ? .none : .deflate
            ) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        guard let out = archive.data else { throw FolioSheetsError.unreadableFile("Couldn't build the file.") }
        return out
    }
}
