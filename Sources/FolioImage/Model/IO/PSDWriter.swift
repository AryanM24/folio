import CoreGraphics
import CoreImage
import FolioKit
import Foundation

/// A layered Photoshop file per the Adobe spec (8-bit RGB, PackBits channels, layer names,
/// blend modes, opacity and visibility), plus the flattened composite that other apps show.
///
/// Folio layers are rasterized one by one, through the same compositor as preview and save,
/// and then put through the document geometry (crop, turns, straighten). Layers that work on
/// what is below them (adjustments, retouch, clipped and pass-through layers) have no PSD
/// equivalent, so they are merged with everything below into one layer. Markup becomes the
/// top layer. A recipe with a redaction writes only the flattened image, so nothing the
/// redaction covers survives in a lower layer.
///
/// shortcut: masks are baked into layer alpha (no PSD user masks) and Resize is ignored; add
/// both when a user asks.
nonisolated enum PSDWriter {
    struct PSDLayer {
        var name: String
        var image: CGImage
        var blend: Layer.BlendMode = .normal
        var opacity = 1.0
        var isVisible = true
    }

    static func layeredPSD(source: SourceImage, recipe: EditRecipe, assets: any AssetStore) throws -> Data {
        var flat = recipe
        flat.resize = nil
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let graph = try RenderPipeline.composite(source, recipe: flat, assets: assets, final: true)
        guard max(graph.extent.width, graph.extent.height) <= 30_000 else {
            throw FolioError("Photoshop files can be at most 30,000 pixels on a side. Crop or resize the image first.")
        }
        let composite = try RenderPipeline.rasterize(graph.image, extent: graph.extent, format: .RGBA8, colorSpace: space)
        let layers =
            recipe.containsRedaction
            ? [PSDLayer(name: "Background", image: composite)]
            : try stack(source: source, recipe: flat, assets: assets, extent: graph.extent, space: space, composite: composite)
        return encode(layers: layers, composite: composite)
    }

    /// The Folio layer stack as PSD layers, bottom first.
    private static func stack(
        source: SourceImage, recipe: EditRecipe, assets: any AssetStore, extent: CGRect, space: CGColorSpace, composite: CGImage
    ) throws -> [PSDLayer] {
        let geometry = ImageGeometry(sourceSize: source.pixelSize, recipe: recipe)
        let r = geometry.recipe
        guard !r.layers.isEmpty || !r.markup.isEmpty else { return [PSDLayer(name: "Background", image: composite)] }
        // The vignette frames the whole picture, so only the background gets it.
        var plain = r
        plain.adjustments[.vignette] = 0
        let layerGeometry = ImageGeometry(sourceSize: source.pixelSize, recipe: plain)
        func place(_ image: CIImage, _ geometry: ImageGeometry) throws -> CGImage {
            let placed = RenderPipeline.transformed(image, geometry: geometry, scale: 1, cropped: true)
            return try RenderPipeline.rasterize(placed, extent: extent, format: .RGBA8, colorSpace: space)
        }
        let input = try RenderPipeline.input(for: source, raw: r.raw, scale: 1)
        let base = RenderPipeline.filtered(
            input, recipe: r, assets: assets, scale: 1, mask: r.removeBackground ? try source.subjectMask() : nil)
        let clear = CIImage(color: .clear).cropped(to: base.extent)
        var out = [PSDLayer(name: "Background", image: try place(base, geometry))]
        for (index, layer) in r.layers.enumerated() where layer.isVisible || !needsBelow(layer) {
            if needsBelow(layer) {
                let merged = LayerCompositor.composite(base: base, layers: Array(r.layers[...index]), assets: assets, scale: 1)
                out = [PSDLayer(name: "Background", image: try place(merged, geometry))]
                continue
            }
            var solo = layer
            solo.blend = .normal
            solo.opacity = 1
            solo.isVisible = true
            let pixels = LayerCompositor.composite(base: clear, layers: [solo], assets: assets, scale: 1)
            out.append(
                PSDLayer(
                    name: layer.name, image: try place(pixels, layerGeometry), blend: layer.blend, opacity: layer.opacity,
                    isVisible: layer.isVisible))
        }
        if !r.markup.isEmpty, let overlay = MarkupDrawing.image(r.markup, size: extent.size, transform: geometry.outputTransform) {
            out.append(PSDLayer(name: "Markup", image: overlay))
        }
        return out
    }

    /// Layers whose look depends on the pixels below them.
    private static func needsBelow(_ layer: Layer) -> Bool {
        if layer.clipsToBelow { return true }
        switch layer.content {
        case .adjustment, .retouch: return true
        case .group(let group): return group.passThrough
        default: return false
        }
    }
}

// MARK: - Encoding

nonisolated extension PSDWriter {
    static func encode(layers: [PSDLayer], composite: CGImage) -> Data {
        let flat = Bitmap(composite)
        let hasAlpha = flat.hasTransparency
        var out = Writer()
        out.ascii("8BPS")
        out.u16(1)
        out.zeros(6)
        out.u16(hasAlpha ? 4 : 3)
        out.u32(flat.height)
        out.u32(flat.width)
        out.u16(8)
        out.u16(3)  // RGB
        out.u32(0)  // color mode data
        out.u32(0)  // image resources

        var info = Writer()
        info.u16(layers.count)
        var channelData = Writer()
        for layer in layers {
            let bitmap = Bitmap(layer.image)
            let box = bitmap.contentBounds
            info.u32(box.minY)
            info.u32(box.minX)
            info.u32(box.maxY)
            info.u32(box.maxX)
            info.u16(4)
            // Channel IDs: -1 transparency, 0 red, 1 green, 2 blue.
            for (id, channel) in [(0xFFFF, 3), (0, 0), (1, 1), (2, 2)] {
                let rows = packedRows(bitmap, channel: channel, box: box)
                info.u16(id)
                info.u32(2 + 2 * rows.count + rows.reduce(0) { $0 + $1.count })
                channelData.u16(1)  // PackBits
                for row in rows { channelData.u16(row.count) }
                for row in rows { channelData.bytes(row) }
            }
            info.ascii("8BIM")
            info.ascii(layer.blend.psdKey)
            info.u8(Int((min(1, max(0, layer.opacity)) * 255).rounded()))
            info.u8(0)  // base clipping
            info.u8(layer.isVisible ? 0 : 2)  // bit 1 set = hidden
            info.u8(0)
            let name = pascalName(layer.name)
            info.u32(8 + name.count)
            info.u32(0)  // layer mask data
            info.u32(0)  // blending ranges
            info.bytes(name)
        }
        info.bytes(channelData.data)
        if info.data.count % 2 == 1 { info.u8(0) }
        out.u32(4 + info.data.count + 4)
        out.u32(info.data.count)
        out.bytes(info.data)
        out.u32(0)  // global layer mask

        let full = Box(minX: 0, minY: 0, maxX: flat.width, maxY: flat.height)
        let channels = (0..<(hasAlpha ? 4 : 3)).map { packedRows(flat, channel: $0, box: full) }
        out.u16(1)
        for rows in channels { for row in rows { out.u16(row.count) } }
        for rows in channels { for row in rows { out.bytes(row) } }
        return out.data
    }

    /// One channel of `box`, row by row, PackBits-compressed.
    private static func packedRows(_ bitmap: Bitmap, channel: Int, box: Box) -> [[UInt8]] {
        (box.minY..<box.maxY).map { y in
            packBits((box.minX..<box.maxX).map { bitmap.bytes[(y * bitmap.width + $0) * 4 + channel] })
        }
    }

    /// Apple/Adobe PackBits: runs of 2–128 equal bytes as (1 − n, byte); literals as (n − 1, bytes…).
    static func packBits(_ row: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(row.count + row.count / 128 + 1)
        var i = 0
        while i < row.count {
            var run = 1
            while i + run < row.count, run < 128, row[i + run] == row[i] { run += 1 }
            if run >= 2 {
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(row[i])
                i += run
                continue
            }
            var end = i + 1
            while end < row.count, end - i < 128, !(end + 1 < row.count && row[end] == row[end + 1]) { end += 1 }
            out.append(UInt8(end - i - 1))
            out.append(contentsOf: row[i..<end])
            i = end
        }
        return out
    }

    /// A Pascal string padded so length byte plus text is a multiple of 4.
    private static func pascalName(_ name: String) -> [UInt8] {
        let text = Array((name.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()).prefix(255))
        var out = [UInt8(text.count)] + text
        while out.count % 4 != 0 { out.append(0) }
        return out
    }
}

// MARK: - Helpers

nonisolated extension PSDWriter {
    /// Big-endian byte writer.
    struct Writer {
        var data = Data()
        mutating func u8(_ v: Int) { data.append(UInt8(truncatingIfNeeded: v)) }
        mutating func u16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).bigEndian) { data.append(contentsOf: $0) } }
        mutating func u32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).bigEndian) { data.append(contentsOf: $0) } }
        mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: n)) }
        mutating func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
        mutating func bytes(_ d: Data) { data.append(d) }
    }

    struct Box {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
    }

    /// Straight (not premultiplied) 8-bit RGBA, top row first, in sRGB.
    struct Bitmap {
        let width: Int
        let height: Int
        var bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let (w, h) = (width, height)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let a = Int(bytes[i + 3])
                guard a != 0, a != 255 else { continue }
                for c in 0..<3 { bytes[i + c] = UInt8(min(255, (Int(bytes[i + c]) * 255 + a / 2) / a)) }
            }
            self.bytes = bytes
        }

        var hasTransparency: Bool { stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] != 255 } }

        /// The smallest rectangle holding every non-transparent pixel (at least 1×1).
        var contentBounds: Box {
            var box = Box(minX: width, minY: height, maxX: 0, maxY: 0)
            for y in 0..<height {
                for x in 0..<width where bytes[(y * width + x) * 4 + 3] != 0 {
                    box.minX = min(box.minX, x)
                    box.maxX = max(box.maxX, x + 1)
                    box.minY = min(box.minY, y)
                    box.maxY = max(box.maxY, y + 1)
                }
            }
            return box.maxX > box.minX ? box : Box(minX: 0, minY: 0, maxX: 1, maxY: 1)
        }
    }
}

nonisolated extension Layer.BlendMode {
    /// The four-character Photoshop blend mode key.
    var psdKey: String {
        switch self {
        case .normal: "norm"
        case .dissolve: "diss"
        case .darken: "dark"
        case .multiply: "mul "
        case .colorBurn: "idiv"
        case .linearBurn: "lbrn"
        case .darkerColor: "dkCl"
        case .lighten: "lite"
        case .screen: "scrn"
        case .colorDodge: "div "
        case .linearDodge: "lddg"
        case .lighterColor: "lgCl"
        case .overlay: "over"
        case .softLight: "sLit"
        case .hardLight: "hLit"
        case .vividLight: "vLit"
        case .linearLight: "lLit"
        case .pinLight: "pLit"
        case .hardMix: "hMix"
        case .difference: "diff"
        case .exclusion: "smud"
        case .subtract: "fsub"
        case .divide: "fdiv"
        case .hue: "hue "
        case .saturation: "sat "
        case .color: "colr"
        case .luminosity: "lum "
        }
    }
}
