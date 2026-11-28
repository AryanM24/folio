import FolioKit
import Foundation

/// An Adobe/Resolve `.cube` LUT, parsed into what `CIColorCubeWithColorSpace` takes.
///
/// `.cube` stores red fastest, as Core Image wants, so 3D tables are passed through. 1D
/// tables are expanded into a 3D cube. `DOMAIN_MIN/MAX` (and Resolve's `LUT_*_INPUT_RANGE`)
/// are honoured by scaling the input first (`EffectGraph`).
nonisolated struct CubeLUT: Equatable, Sendable {
    var title: String?
    /// Entries per axis of `cube`.
    var size: Int
    var domainMin: [Double] = [0, 0, 0]
    var domainMax: [Double] = [1, 1, 1]
    /// RGBA float32, red fastest, alpha 1: `CIColorCube`'s `cubeData`.
    var cube: Data

    /// Core Image's limit.
    static let maxSize = 128

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FolioError("This LUT file isn't text, so it isn't a .cube file.")
        }
        var size3D: Int?
        var size1D: Int?
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            switch parts[0] {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE": size3D = parts.count > 1 ? Int(parts[1]) : nil
            case "LUT_1D_SIZE": size1D = parts.count > 1 ? Int(parts[1]) : nil
            case "DOMAIN_MIN": domainMin = try Self.triple(parts)
            case "DOMAIN_MAX": domainMax = try Self.triple(parts)
            case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                guard parts.count == 3, let lo = Double(parts[1]), let hi = Double(parts[2]) else { throw Self.malformed }
                domainMin = [lo, lo, lo]
                domainMax = [hi, hi, hi]
            default:
                guard parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]),
                    r.isFinite, g.isFinite, b.isFinite
                else {
                    // Unknown keywords (LUT_IN_VIDEO_RANGE…) are skipped, as other readers do.
                    if parts[0].first?.isLetter == true { continue }
                    throw Self.malformed
                }
                values += [r, g, b]
            }
        }
        guard zip(domainMin, domainMax).allSatisfy({ $0 < $1 }) else { throw FolioError("This LUT's DOMAIN_MIN isn't below its DOMAIN_MAX.") }
        if let n = size3D {
            guard (2...Self.maxSize).contains(n) else { throw FolioError("Folio reads LUTs of 2 to \(Self.maxSize) points per axis; this one has \(n).") }
            guard values.count == n * n * n * 3 else { throw Self.wrongCount(values.count / 3, n * n * n) }
            size = n
            var rgba = [Float](repeating: 1, count: n * n * n * 4)
            for i in 0..<(n * n * n) {
                rgba[i * 4] = values[i * 3]
                rgba[i * 4 + 1] = values[i * 3 + 1]
                rgba[i * 4 + 2] = values[i * 3 + 2]
            }
            cube = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        } else if let n = size1D {
            guard n >= 2, n <= 65_536 else { throw FolioError("This 1D LUT has \(n) entries; Folio reads 2 to 65536.") }
            guard values.count == n * 3 else { throw Self.wrongCount(values.count / 3, n) }
            size = 64
            cube = Self.expand(oneD: values, entries: n, to: size)
        } else {
            throw FolioError("This file has no LUT_3D_SIZE or LUT_1D_SIZE line, so it isn't a .cube LUT.")
        }
    }

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    var hasUnitDomain: Bool { domainMin == [0, 0, 0] && domainMax == [1, 1, 1] }

    /// A 1D table (one curve per channel) as a 3D cube, linearly interpolated.
    private static func expand(oneD values: [Float], entries n: Int, to size: Int) -> Data {
        func sample(_ channel: Int, _ x: Float) -> Float {
            let p = x * Float(n - 1)
            let i = min(Int(p), n - 2)
            let f = p - Float(i)
            return values[i * 3 + channel] * (1 - f) + values[(i + 1) * 3 + channel] * f
        }
        let axis = (0..<size).map { Float($0) / Float(size - 1) }
        let r = axis.map { sample(0, $0) }, g = axis.map { sample(1, $0) }, b = axis.map { sample(2, $0) }
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        for bi in 0..<size {
            for gi in 0..<size {
                for ri in 0..<size { rgba += [r[ri], g[gi], b[bi], 1] }
            }
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func triple(_ parts: [Substring]) throws -> [Double] {
        let numbers = parts.dropFirst().compactMap { Double($0) }
        guard numbers.count == 3 else { throw malformed }
        return numbers
    }

    private static let malformed = FolioError("This LUT file has a line Folio can't read, so it may be damaged or not a .cube file.")

    private static func wrongCount(_ found: Int, _ expected: Int) -> FolioError {
        FolioError("This LUT should have \(expected) entries but has \(found), so it may be cut short.")
    }
}
