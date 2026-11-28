import CoreGraphics
import CoreImage
import FolioKit
import Foundation
import ImageIO

/// Turns a ``SelectionSpec`` into a mask, for the marching ants, masks from selections
/// and every tool that respects a selection.
///
/// Masks are opaque grayscale images (r = g = b = coverage, alpha 1) without color
/// management, so 0.5 means half selected in any working space.
nonisolated enum SelectionRenderer {
    /// Pixel-based shapes (wand, color range, subject, sky) are analysed on at most this
    /// many pixels on the long edge, then scaled up: Vision runs at a fixed internal size
    /// anyway, and it keeps preview and full-size masks the same.
    static let analysisMaxPixels = SourceImage.proxyMaxPixels

    /// `spec` as a grayscale mask (white = selected) over a `size` (source pixels) image
    /// at `scale`, in Core Image coordinates: origin bottom-left, extent = `size` × `scale`.
    /// `pixels` is what the wand, color range, subject and sky shapes analyse, at the same
    /// scale; without it they select nothing. `assets` resolves saved selections
    /// (`.pixels`); without it they select nothing.
    static func mask(
        _ spec: SelectionSpec, size: CGSize, scale: Double, pixels: CIImage? = nil, assets: (any AssetStore)? = nil
    ) throws -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        var analysis: Analysis?
        func analysed() -> Analysis? {
            if analysis == nil, let pixels { analysis = Analysis(pixels, extent: extent) }
            return analysis
        }

        var acc = black(extent)
        for op in spec.ops {
            let shape = try self.shape(op.shape, extent: extent, scale: scale, analysis: analysed, assets: assets)
            switch op.mode {
            case .add: acc = shape.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: acc])
            case .subtract:
                acc = shape.applyingFilter("CIColorInvert")
                    .applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: acc])
            case .intersect: acc = shape.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: acc])
            }
        }
        acc = MaskRefine.refine(
            acc.cropped(to: extent), feather: spec.feather, expand: spec.expand, smooth: spec.smooth, edge: spec.refineEdge,
            guide: pixels, scale: scale)
        if spec.inverted { acc = acc.applyingFilter("CIColorInvert") }
        return acc.cropped(to: extent)
    }

    // MARK: Shapes

    private static func shape(
        _ shape: SelectionSpec.Shape, extent: CGRect, scale: Double, analysis: () -> Analysis?, assets: (any AssetStore)?
    ) throws -> CIImage {
        switch shape {
        case .all: return CIImage(color: .white).cropped(to: extent)
        case .rect(let r): return fill(CGPath(rect: r, transform: nil), extent: extent, scale: scale)
        case .ellipse(let r): return fill(CGPath(ellipseIn: r, transform: nil), extent: extent, scale: scale)
        case .polygon(let points):
            guard points.count > 2 else { return black(extent) }
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            return fill(path, extent: extent, scale: scale)
        case .path(let vector): return fill(vector.cgPath, extent: extent, scale: scale)
        case .pixels(let id):
            guard let assets, let image = decode(try assets.data(id)) else { return black(extent) }
            return stretched(image, to: extent)
        case .wand(let seed, let tolerance, let contiguous, _):
            guard let a = analysis() else { return black(extent) }
            let mask = MagicWand.mask(seed: a.point(seed, scale: scale), tolerance: tolerance, contiguous: contiguous, in: a.image)
            return a.upscaled(mask, to: extent)
        case .colorRange(let color, let fuzziness):
            guard let a = analysis() else { return black(extent) }
            return a.upscaled(MagicWand.colorRange(color, fuzziness: fuzziness, in: a.image), to: extent)
        case .subject, .people, .sky:
            guard let a = analysis() else { return black(extent) }
            return a.upscaled(try SubjectSelector.mask(shape, in: a.image), to: extent)
        }
    }

    /// `pixels` rasterized for analysis, and the factor from mask pixels to analysis pixels.
    private struct Analysis {
        let image: CGImage
        let factor: Double

        init?(_ pixels: CIImage, extent: CGRect) {
            let long = max(extent.width, extent.height)
            let shrink = min(1, Double(SelectionRenderer.analysisMaxPixels) / max(1, long))
            let small =
                shrink < 1 ? pixels.transformed(by: CGAffineTransform(scaleX: shrink, y: shrink), highQualityDownsample: true) : pixels
            guard let image = SelectionRenderer.analysisImage(small, extent: extent.applying(CGAffineTransform(scaleX: shrink, y: shrink)))
            else { return nil }
            self.image = image
            factor = Double(image.width) / max(1, extent.width)
        }

        /// A source-pixel point in the analysis image (top-left origin).
        func point(_ p: CGPoint, scale: Double) -> CGPoint { CGPoint(x: p.x * scale * factor, y: p.y * scale * factor) }

        func upscaled(_ mask: CIImage?, to extent: CGRect) -> CIImage {
            guard let mask else { return SelectionRenderer.black(extent) }
            return SelectionRenderer.stretched(mask, to: extent)
        }
    }

    // MARK: Helpers

    /// What the pixel-based shapes analyse: `pixels` over `extent` as 8-bit sRGB. The
    /// model and the renderer both go through here, so Vision's cache sees the same bytes.
    static func analysisImage(_ pixels: CIImage, extent: CGRect) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: max(1, extent.width.rounded()), height: max(1, extent.height.rounded()))
        return RenderPipeline.context.createCGImage(
            pixels, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func black(_ extent: CGRect) -> CIImage { CIImage(color: .black).cropped(to: extent) }

    /// Fill `path` (source pixels, top-left origin) into an antialiased mask over `extent`.
    private static func fill(_ path: CGPath, extent: CGRect, scale: Double) -> CIImage {
        let w = Int(extent.width.rounded(.up)), h = Int(extent.height.rounded(.up))
        guard w > 0, h > 0,
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return black(extent) }
        // Source pixels are y-down. Bitmap y equals Core Image y, so the top is `extent.height`.
        ctx.translateBy(x: 0, y: extent.height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.addPath(path)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath()
        guard let image = ctx.makeImage() else { return black(extent) }
        return maskImage(image).cropped(to: extent)
    }

    /// A grayscale bitmap as a mask, without color management.
    static func maskImage(_ image: CGImage) -> CIImage {
        CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    /// An 8-bit grayscale mask from bytes (row 0 at the top).
    static func maskImage(_ bytes: [UInt8], width: Int, height: Int) -> CIImage? {
        grayImage(bytes, width: width, height: height).map(maskImage)
    }

    static func grayImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The coverage of `mask` as bytes, row 0 at the top.
    static func bytes(of mask: CIImage) -> (bytes: [UInt8], width: Int, height: Int) {
        let rect = mask.extent.integral
        let w = Int(rect.width), h = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: max(0, w * h))
        guard w > 0, h > 0 else { return (bytes, 0, 0) }
        bytes.withUnsafeMutableBytes { buffer in
            RenderPipeline.context.render(
                mask, toBitmap: buffer.baseAddress!, rowBytes: w, bounds: rect, format: .L8, colorSpace: nil)
        }
        return (bytes, w, h)
    }

    /// The mask as an 8-bit grayscale PNG, for saved selections.
    static func png(of mask: CIImage) throws -> Data {
        let (bytes, w, h) = bytes(of: mask)
        guard let image = grayImage(bytes, width: w, height: h) else { throw FolioError("Folio couldn't save this selection.") }
        return try ImageCodec.encode(image, as: .png)
    }

    private static func decode(_ data: Data) -> CIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return maskImage(image)
    }

    /// Any mask (Vision's one-channel buffers included) stretched over `extent`, with its
    /// first channel copied to r, g and b and alpha set to 1.
    static func stretched(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let e = mask.extent
        guard e.width > 0, e.height > 0 else { return black(extent) }
        let transform = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: extent.width / e.width, y: extent.height / e.height))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let red = CIVector(x: 1, y: 0, z: 0, w: 0)
        return mask.clampedToExtent().transformed(by: transform)
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": red, "inputGVector": red, "inputBVector": red,
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ]
            )
            .cropped(to: extent)
    }
}
