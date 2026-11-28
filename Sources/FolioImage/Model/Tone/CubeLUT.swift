import FolioKit
import Foundation

/// An Adobe `.cube` LUT (1D or 3D), parsed. Autodesk `.3dl` files are read too and
/// come out as an equivalent 3D cube.
nonisolated struct CubeLUT: Equatable, Sendable {
    var title: String?
    /// 1 or 3.
    var dimension: Int
    /// Entries per axis.
    var size: Int
    var domainMin: [Double]
    var domainMax: [Double]
    /// RGB triples, red varying fastest.
    var values: [Float]

    /// Core Image's color cube limit.
    static let maxSize3D = 128
    static let maxSize1D = 65536

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FolioError("This LUT file isn't text.")
        }
        if text.contains("LUT_3D_SIZE") || text.contains("LUT_1D_SIZE") {
            try self.init(cube: text)
        } else {
            try self.init(threeDL: text)
        }
    }

    private init(cube text: String) throws {
        (title, dimension, size, domainMin, domainMax, values) = (nil, 0, 0, [0, 0, 0], [1, 1, 1], [])
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            guard let first = line.first else { continue }
            let words = line.split(whereSeparator: \.isWhitespace)
            if first.isLetter {
                let keyword = words[0].uppercased()
                let numbers = words.dropFirst().compactMap { Double($0) }
                switch keyword {
                case "TITLE":
                    title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                case "LUT_1D_SIZE", "LUT_3D_SIZE":
                    guard dimension == 0, numbers.count == 1, let n = Int(exactly: numbers[0]) else {
                        throw FolioError("This LUT file has a bad size line.")
                    }
                    (dimension, size) = (keyword == "LUT_1D_SIZE" ? 1 : 3, n)
                case "DOMAIN_MIN", "DOMAIN_MAX":
                    guard numbers.count == 3 else { throw FolioError("This LUT file has a bad domain line.") }
                    if keyword == "DOMAIN_MIN" { domainMin = numbers } else { domainMax = numbers }
                case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":  // DaVinci Resolve's spelling
                    guard numbers.count == 2 else { throw FolioError("This LUT file has a bad input range line.") }
                    (domainMin, domainMax) = ([numbers[0], numbers[0], numbers[0]], [numbers[1], numbers[1], numbers[1]])
                default:
                    break  // Unknown keywords are allowed by the spec.
                }
                continue
            }
            let triple = words.compactMap { Float($0) }
            guard triple.count == 3, words.count == 3, triple.allSatisfy(\.isFinite) else {
                throw FolioError("This LUT file has a line Folio can't read: “\(line.prefix(40))”.")
            }
            values += triple
        }
        try validate()
    }

    /// `.3dl`: an optional line of input shaper values, then integer RGB triples with
    /// blue varying fastest, scaled to the file's bit depth.
    private init(threeDL text: String) throws {
        (title, dimension, size, domainMin, domainMax, values) = (nil, 3, 0, [0, 0, 0], [1, 1, 1], [])
        var rows: [[Double]] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let numbers = line.split(whereSeparator: \.isWhitespace).map { Double($0) }
            if numbers.isEmpty { continue }
            guard numbers.allSatisfy({ $0 != nil }) else { throw FolioError("This isn't a .cube or .3dl LUT file.") }
            let row = numbers.compactMap { $0 }
            if row.count == 3 {
                rows.append(row)
            } else if !rows.isEmpty || row.count < 2 {
                throw FolioError("This isn't a .cube or .3dl LUT file.")
            }
        }
        size = Int(cbrt(Double(rows.count)).rounded())
        guard size * size * size == rows.count else { throw FolioError("This .3dl LUT has \(rows.count) entries, which isn't a cube.") }
        let peak = rows.joined().max() ?? 1
        let scale = [1023.0, 4095.0, 16383.0, 65535.0].first { peak <= $0 } ?? peak
        values = [Float](repeating: 0, count: rows.count * 3)
        // File order is r slowest, b fastest; ours is r fastest.
        for (i, row) in rows.enumerated() {
            let (r, g, b) = (i / (size * size), (i / size) % size, i % size)
            let j = ((b * size + g) * size + r) * 3
            for c in 0..<3 { values[j + c] = Float(row[c] / scale) }
        }
        try validate()
    }

    private func validate() throws {
        guard dimension != 0 else { throw FolioError("This LUT file doesn't say its size.") }
        let limit = dimension == 3 ? Self.maxSize3D : Self.maxSize1D
        guard (2...limit).contains(size) else { throw FolioError("Folio can't use a LUT of size \(size).") }
        let expected = (dimension == 3 ? size * size * size : size) * 3
        guard values.count == expected else {
            throw FolioError("This LUT file should have \(expected / 3) entries but has \(values.count / 3).")
        }
        guard zip(domainMin, domainMax).allSatisfy({ $0 < $1 }) else { throw FolioError("This LUT file has an empty domain.") }
    }
}
