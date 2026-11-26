import Compression
import Foundation

/// Just enough ZIP to read and write Word (.docx) packages: deflate and stored
/// entries, no encryption, no ZIP64.
///
/// Shortcut: FolioDocs depends only on FolioKit, so it can't use the ZIPFoundation
/// package that FolioSheets links. Swap this for ZIPFoundation if the package graph
/// lets FolioDocs depend on it, or if documents over 4 GB ever matter.
nonisolated enum ZipArchive {
    struct Entry {
        let path: String
        let data: Data
    }

    // MARK: Writing

    /// A ZIP file containing `entries` in order. Entries are deflated unless that
    /// doesn't make them smaller.
    static func archive(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let deflated = deflate(entry.data)
            let (method, payload): (UInt16, Data) =
                if let deflated, deflated.count < entry.data.count { (8, deflated) } else { (0, entry.data) }
            let offset = UInt32(out.count)

            out.append(le32: 0x0403_4b50)
            out.append(le16: 20); out.append(le16: 0x0800); out.append(le16: method)
            out.append(le16: 0); out.append(le16: 0x21)  // time, date (1980-01-01): stable output
            out.append(le32: crc); out.append(le32: UInt32(payload.count)); out.append(le32: UInt32(entry.data.count))
            out.append(le16: UInt16(name.count)); out.append(le16: 0)
            out.append(name); out.append(payload)

            central.append(le32: 0x0201_4b50)
            central.append(le16: 20); central.append(le16: 20); central.append(le16: 0x0800); central.append(le16: method)
            central.append(le16: 0); central.append(le16: 0x21)
            central.append(le32: crc); central.append(le32: UInt32(payload.count)); central.append(le32: UInt32(entry.data.count))
            central.append(le16: UInt16(name.count)); central.append(le16: 0); central.append(le16: 0)
            central.append(le16: 0); central.append(le16: 0); central.append(le32: 0)
            central.append(le32: offset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32: 0x0605_4b50)
        out.append(le16: 0); out.append(le16: 0)
        out.append(le16: UInt16(entries.count)); out.append(le16: UInt16(entries.count))
        out.append(le32: UInt32(central.count)); out.append(le32: centralOffset)
        out.append(le16: 0)
        return out
    }

    // MARK: Reading

    /// The uncompressed contents of `path` inside a ZIP, or `nil` if it isn't there or
    /// can't be decoded.
    static func read(_ path: String, from zip: Data) -> Data? {
        let bytes = [UInt8](zip)
        guard bytes.count >= 22 else { return nil }
        // End of central directory: scan back over a possible archive comment.
        var eocd = bytes.count - 22
        while eocd >= max(0, bytes.count - 22 - 65_535) {
            if bytes.u32(eocd) == 0x0605_4b50 { break }
            eocd -= 1
        }
        guard eocd >= 0, bytes.u32(eocd) == 0x0605_4b50 else { return nil }
        let count = Int(bytes.u16(eocd + 10))
        var p = Int(bytes.u32(eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= bytes.count, bytes.u32(p) == 0x0201_4b50 else { return nil }
            let method = bytes.u16(p + 10)
            let compressedSize = Int(bytes.u32(p + 20))
            let size = Int(bytes.u32(p + 24))
            let nameLength = Int(bytes.u16(p + 28))
            let extra = Int(bytes.u16(p + 30)) + Int(bytes.u16(p + 32))
            let local = Int(bytes.u32(p + 42))
            guard p + 46 + nameLength <= bytes.count else { return nil }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extra
            guard name == path else { continue }
            guard local + 30 <= bytes.count else { return nil }
            let start = local + 30 + Int(bytes.u16(local + 26)) + Int(bytes.u16(local + 28))
            guard start + compressedSize <= bytes.count else { return nil }
            let payload = Data(bytes[start..<(start + compressedSize)])
            switch method {
            case 0: return payload
            case 8: return inflate(payload, size: size)
            default: return nil
            }
        }
        return nil
    }

    // MARK: Codecs

    /// Raw DEFLATE (RFC 1951), which is what `COMPRESSION_ZLIB` produces and ZIP stores.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                // Both buffers are non-empty (guarded above), so their base addresses exist.
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    private static func inflate(_ data: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        guard !data.isEmpty else { return nil }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                // Both buffers are non-empty (guarded above), so their base addresses exist.
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private nonisolated extension Data {
    mutating func append(le16 v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

private nonisolated extension [UInt8] {
    func u16(_ i: Int) -> UInt16 { i + 1 < count ? UInt16(self[i]) | UInt16(self[i + 1]) << 8 : 0 }
    func u32(_ i: Int) -> UInt32 { i + 3 < count ? UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 : 0 }
}
