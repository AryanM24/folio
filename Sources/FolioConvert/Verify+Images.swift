import CoreGraphics
import Foundation
import ImageIO

/// Sample-level comparison of two renderings, for verifying lossless claims.
///
/// Both sides are drawn into the same sRGB RGBA buffer, 8-bit or 16-bit: an 8-bit compare
/// would hide loss in 16-bit sources (research §5).
nonisolated struct PixelDiff {
    var maxDelta: Double
    var differing: Int
    var samples: Int
    /// `nil` when identical (PSNR is infinite, which JSON can't hold).
    var psnr: Double?

    var identical: Bool { differing == 0 }

    var metrics: [String: Double] {
        var m = ["max_delta": maxDelta, "differing_samples": Double(differing)]
        if let psnr { m["psnr"] = (psnr * 100).rounded() / 100 }
        return m
    }

    /// Compares two images pixel for pixel; `nil` when their sizes differ.
    init?(_ a: CGImage, _ b: CGImage, wide: Bool) {
        guard a.width == b.width, a.height == b.height else { return nil }
        let draw = { (image: CGImage) in
            { (context: CGContext) in context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)) }
        }
        self.init(width: a.width, height: a.height, wide: wide, white: false, draw(a), draw(b))
    }

    /// Compares two drawings of `width`×`height` pixels, optionally over white (for pages).
    init(width: Int, height: Int, wide: Bool, white: Bool, _ a: (CGContext) -> Void, _ b: (CGContext) -> Void) {
        if wide {
            self = Self.compare(
                Self.render(UInt16.self, width, height, white, a), Self.render(UInt16.self, width, height, white, b), peak: 65535)
        } else {
            self = Self.compare(
                Self.render(UInt8.self, width, height, white, a), Self.render(UInt8.self, width, height, white, b), peak: 255)
        }
    }

    private init(maxDelta: Double, differing: Int, samples: Int, psnr: Double?) {
        (self.maxDelta, self.differing, self.samples, self.psnr) = (maxDelta, differing, samples, psnr)
    }

    static func render<T: FixedWidthInteger & UnsignedInteger>(
        _: T.Type, _ width: Int, _ height: Int, _ white: Bool, _ draw: (CGContext) -> Void
    ) -> [T] {
        var buffer = [T](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | (T.bitWidth == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        buffer.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: T.bitWidth,
                    bytesPerRow: width * 4 * T.bitWidth / 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
            else { return }
            if white {
                context.setFillColor(.white)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            draw(context)
        }
        return buffer
    }

    static func compare<T: FixedWidthInteger & UnsignedInteger>(_ a: [T], _ b: [T], peak: Double) -> PixelDiff {
        let same = a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in pa.count == pb.count && memcmp(pa.baseAddress!, pb.baseAddress!, pa.count) == 0 }
        }
        if same { return PixelDiff(maxDelta: 0, differing: 0, samples: a.count, psnr: nil) }
        var maxDelta = 0.0, differing = 0, squared = 0.0
        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
            let d = Double(a[i] > b[i] ? a[i] - b[i] : b[i] - a[i])
            differing += 1
            maxDelta = max(maxDelta, d)
            squared += d * d
        }
        let mse = squared / Double(a.count)
        return PixelDiff(maxDelta: maxDelta, differing: differing, samples: a.count, psnr: 10 * log10(peak * peak / mse))
    }
}

extension ImageConverter {
    /// Decodes the written output and the input to the same pixel format and compares them.
    /// Lossless claims pass only when every sample matches; lossy ones pass and report PSNR.
    static func verify(job: Job, fidelity: Fidelity, strip: Bool) throws -> Verification {
        guard let output = try? open(job.output), let produced = CGImageSourceCreateImageAtIndex(output, 0, nil) else {
            return Verification(passed: false, checks: ["opens"])
        }
        let input = try open(job.input)
        let props = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        let wide = (props[kCGImagePropertyDepth] as? Int ?? 8) > 8
        var checks = ["opens"]
        var passed = true
        if strip {
            let outProps = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any] ?? [:]
            checks.append("no GPS")
            passed = outProps[kCGImagePropertyGPSDictionary] == nil
        }
        // A resized output was decoded upright; compare it with an upright decode at its size.
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0, height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let original =
            (produced.width == width && produced.height == height)
            ? CGImageSourceCreateImageAtIndex(input, 0, nil)
            : CGImageSourceCreateThumbnailAtIndex(
                input, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(produced.width, produced.height),
                ] as CFDictionary)
        guard let original, let diff = PixelDiff(original, produced, wide: wide) else {
            return Verification(passed: false, checks: checks + ["same size"])
        }
        if fidelity == .lossless {
            checks.append("pixels identical")
            passed = passed && diff.identical
        } else {
            checks.append("psnr")
        }
        return Verification(passed: passed, checks: checks, metrics: diff.metrics)
    }
}
