import Foundation
import FolioKit

/// Character encodings Folio reads and writes. Detected on open and kept on save, so
/// editing a file never silently re-encodes it.
public nonisolated enum TextEncoding: String, CaseIterable, Identifiable, Sendable {
    case utf8, utf8BOM, utf16LE, utf16BE, windowsLatin1, isoLatin1, macRoman

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8BOM: "UTF-8 with BOM"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .windowsLatin1: "Windows Latin 1"
        case .isoLatin1: "ISO Latin 1"
        case .macRoman: "Mac Roman"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .windowsLatin1: .windowsCP1252
        case .isoLatin1: .isoLatin1
        case .macRoman: .macOSRoman
        }
    }

    /// Byte-order mark written before the text. UTF-16 always gets one so other apps can
    /// tell the byte order.
    var bom: [UInt8] {
        switch self {
        case .utf8BOM: [0xEF, 0xBB, 0xBF]
        case .utf16LE: [0xFF, 0xFE]
        case .utf16BE: [0xFE, 0xFF]
        default: []
        }
    }
}

public nonisolated enum LineEnding: String, CaseIterable, Identifiable, Sendable {
    case lf, crlf, cr

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }
    /// Shown in the menu, so people who don't know the acronyms can still choose.
    public var detail: String {
        switch self {
        case .lf: "macOS and Linux (LF)"
        case .crlf: "Windows (CRLF)"
        case .cr: "Classic Mac OS (CR)"
        }
    }
    var characters: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }
}

/// How a text file is laid out on disk. The editor always works in `\n`; this records what
/// to convert back to.
public nonisolated struct TextFormat: Hashable, Sendable {
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    public static let standard = TextFormat(encoding: .utf8, lineEnding: .lf)
}

/// Decodes file bytes into editor text and back, preserving encoding and line endings.
///
/// The trailing newline needs no special handling: it is part of the text, and since the
/// text is never trimmed it is written back exactly as it was.
nonisolated enum TextCodec {
    static func decode(_ data: Data) -> (text: String, format: TextFormat) {
        let marked = detectMarkedEncoding(data)
        let body = data.dropFirst(marked.map { data.starts(with: $0.bom) ? $0.bom.count : 0 } ?? 0)
        // Try the marked (or default UTF-8) encoding strictly, then fall back to 8-bit Western.
        // ISO Latin 1 maps every byte, so the last step always succeeds.
        let candidates: [TextEncoding] = [marked ?? .utf8, .windowsLatin1]
        var decoded: (String, TextEncoding)?
        for encoding in candidates {
            if let text = String(data: body, encoding: encoding.stringEncoding) { decoded = (text, encoding); break }
        }
        var (text, encoding) = decoded ?? (String(body.map { Character(Unicode.Scalar($0)) }), .isoLatin1)
        let ending = detectLineEnding(text)
        if ending != .lf || text.utf8.contains(13) {
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        return (text, TextFormat(encoding: encoding, lineEnding: ending))
    }

    static func encode(_ text: String, as format: TextFormat) throws -> Data {
        let body = format.lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: format.lineEnding.characters)
        guard let bytes = body.data(using: format.encoding.stringEncoding, allowLossyConversion: false) else {
            throw FolioError("This text has characters that can’t be saved as \(format.encoding.title). Choose UTF-8 from the encoding menu in the status bar, then try again.")
        }
        return Data(format.encoding.bom) + bytes
    }

    /// An encoding the bytes announce: a byte-order mark, or UTF-16's telltale zero bytes.
    /// `nil` means "try UTF-8".
    static func detectMarkedEncoding(_ data: Data) -> TextEncoding? {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if head.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if head.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        let sample = [UInt8](data.prefix(1024))
        guard sample.count >= 4 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (index, byte) in sample.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = sample.count / 2
        if oddZeros > half * 3 / 5, evenZeros < half / 10 { return .utf16LE }
        if evenZeros > half * 3 / 5, oddZeros < half / 10 { return .utf16BE }
        return nil
    }

    /// The most common line ending in the text; LF when there are none.
    static func detectLineEnding(_ text: String) -> LineEnding {
        var lf = 0, crlf = 0, cr = 0
        let count: (UnsafeBufferPointer<UInt8>) -> Void = { bytes in
            var i = 0
            let n = bytes.count
            while i < n {
                let b = bytes[i]
                if b == 13 {
                    if i + 1 < n, bytes[i + 1] == 10 { crlf += 1; i += 1 } else { cr += 1 }
                } else if b == 10 {
                    lf += 1
                }
                i += 1
            }
        }
        if text.utf8.withContiguousStorageIfAvailable(count) == nil {
            var copy = text
            copy.withUTF8 { count($0) }
        }
        if crlf > lf, crlf >= cr { return .crlf }
        if cr > lf, cr > crlf { return .cr }
        return .lf
    }
}
