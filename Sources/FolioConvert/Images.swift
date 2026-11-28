import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Images conversions, built on ImageIO. No Core Image: a plain format change never needs
/// an eager decode (`AddImageFromSource` is about 2× faster, research §2.1).
public nonisolated enum ImageConverter: FamilyConverter {
    public static let family: Format.Family = .image

    /// What ImageIO reads on every supported macOS.
    static let readable: Set<Format> = [.png, .jpeg, .heic, .avif, .tiff, .gif, .bmp, .jp2, .webp, .jxl]

    /// Probed once: codec lists change between macOS releases (AVIF write especially).
    static let writable: Set<Format> = {
        let ids = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        return Set([Format.png, .jpeg, .heic, .avif, .tiff, .gif, .bmp, .jp2].filter { ids.contains($0.contentType.identifier) })
    }()

    /// Codecs that decode to exactly the pixels they were given (JPEG 2000 only at quality 1).
    static let losslessCodecs: Set<Format> = [.png, .tiff, .bmp, .jp2]

    public static func targets(from source: Format) -> [Target] {
        guard readable.contains(source) else { return [] }
        let images = Format.allCases.filter { writable.contains($0) }.map { to -> Target in
            var drops: [String] = []
            if source == .gif && to != .gif { drops.append("animation") }
            if to == .jpeg { drops.append("transparency") }
            if to == .gif { drops.append("colours beyond 256") }
            if to == source {
                return Target(
                    to: to, fidelity: [.png, .tiff, .bmp].contains(to) ? .lossless : .lossy, losslessAvailable: true, drops: drops,
                    notes: "Compress. Lossless only rewrites metadata (or recompresses PNG/TIFF without loss).")
            }
            return Target(
                to: to, fidelity: [.png, .tiff, .bmp].contains(to) ? .lossless : .lossy, losslessAvailable: losslessCodecs.contains(to),
                drops: drops)
        }
        let embedsAsIs = source == .jpeg || source == .png
        let pdf = Target(
            to: .pdf, fidelity: embedsAsIs ? .lossless : .lossy, losslessAvailable: embedsAsIs, drops: source == .gif ? ["animation"] : [],
            notes: embedsAsIs ? "One page; the image is embedded as is." : "One page; the image is stored as JPEG.")
        return images + [pdf]
    }

    public static func resource(for job: Job) -> Resource { job.target == .heic ? .hardwareImage : .cpu }

    // MARK: Convert

    public static func convert(_ job: Job) async throws -> Outcome {
        let source = try open(job.input)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let limit = job.maxDimension ?? (job.quality == .small ? 2048 : nil)
        let maxPixels = limit.flatMap { max(width, height) > $0 ? $0 : nil }
        if job.quality == .lossless, maxPixels != nil {
            throw ConvertError(.losslessUnavailable, "Resizing can't be lossless.", hint: "Drop max_dimension or use quality balanced.")
        }
        if job.target == .pdf { return try writePDF(source, props: props, job: job, maxPixels: maxPixels) }

        let strip = job.stripMetadata || job.quality == .small
        var outcome: Outcome
        if job.target == job.source, job.quality == .lossless {
            outcome = try copy(source, job: job, strip: strip)
        } else {
            let wide = (props[kCGImagePropertyDepth] as? Int ?? 8) > 8
            let encoded = try encodeWithinBudget(source, job: job, maxPixels: maxPixels, strip: strip)
            try encoded.data.write(to: job.output)
            let exact =
                losslessCodecs.contains(job.target) && encoded.quality ?? 1 >= 1 && encoded.maxPixels == nil
                && job.quality != .small && !(wide && [.bmp, .gif].contains(job.target))
            var details: [String: JSONValue] = [
                "width": .int(Int64(encoded.width)), "height": .int(Int64(encoded.height)), "codec": .string(job.target.rawValue),
            ]
            if let q = encoded.quality, !losslessCodecs.contains(job.target) || q < 1 { details["quality"] = .double(q) }
            if job.target == .heic { details["hardware"] = true }
            var warnings: [String] = []
            if CGImageSourceGetCount(source) > 1, job.target != .gif { warnings.append("Only the first frame was kept.") }
            outcome = Outcome(
                fidelity: exact ? .lossless : .lossy, method: job.target == job.source ? "encode" : "transcode", details: details,
                dropped: targets(from: job.source).first { $0.to == job.target }?.drops ?? [], warnings: warnings)
        }
        if job.verify {
            outcome.verification = try verify(job: job, fidelity: outcome.fidelity, strip: strip)
        }
        return outcome
    }

    static func open(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete
        else { throw ConvertError(.corruptInput, "\(url.lastPathComponent) isn't an image Folio can read.") }
        return source
    }

    /// Same format, lossless: rewrite metadata without touching the compressed pixels.
    static func copy(_ source: CGImageSource, job: Job, strip: Bool) throws -> Outcome {
        guard strip else {
            try FileManager.default.copyItem(at: job.input, to: job.output)
            return Outcome(fidelity: .lossless, method: "copy", details: ["codec": .string(job.target.rawValue)])
        }
        guard let type = CGImageSourceGetType(source),
            let destination = CGImageDestinationCreateWithURL(job.output as CFURL, type, CGImageSourceGetCount(source), nil)
        else { throw ConvertError(.internal, "Couldn't create the output image.") }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(), kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true, kCGImageMetadataShouldExcludeXMP: true,
        ]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else {
            throw ConvertError(
                .losslessUnavailable, "\(job.source.title) metadata can't be removed without re-encoding.", hint: "Use quality balanced.")
        }
        return Outcome(fidelity: .lossless, method: "copy", details: ["codec": .string(job.target.rawValue)], dropped: ["metadata"])
    }

    // MARK: Encode

    struct Encoded {
        var data: Data
        var width: Int, height: Int
        var quality: Double?
        var maxPixels: Int?
    }

    /// Preset quality per target codec (research §3). `nil` for codecs without a quality knob.
    static func quality(for target: Format, _ preset: Quality) -> Double? {
        switch (target, preset) {
        case (.jpeg, .small), (.heic, .small), (.avif, .small), (.jp2, .small): 0.6
        case (.jpeg, _): 0.85
        case (.heic, _): 0.80
        case (.avif, _): 0.7
        case (.jp2, .lossless): 1.0
        case (.jp2, _): 0.85
        default: nil
        }
    }

    /// The preset encode, then for `maxBytes`: binary-search quality (≤6 encodes), then
    /// downscale and search again. Returns the smallest attempt when nothing fits; the
    /// engine turns that into `SIZE_UNREACHABLE`.
    static func encodeWithinBudget(_ source: CGImageSource, job: Job, maxPixels: Int?, strip: Bool) throws -> Encoded {
        let preset = quality(for: job.target, job.quality)
        let first = try encode(source, job: job, quality: preset, maxPixels: maxPixels, strip: strip)
        guard let budget = job.maxBytes, first.data.count > budget, job.quality != .lossless else { return first }
        var smallest = first
        var pixels = maxPixels
        for _ in 0..<3 {
            if let preset {
                let floor = try encode(source, job: job, quality: 0.1, maxPixels: pixels, strip: strip)
                if floor.data.count < smallest.data.count { smallest = floor }
                if floor.data.count <= budget {
                    var best = floor, low = 0.1, high = preset
                    for _ in 0..<5 {
                        let mid = (low + high) / 2
                        let attempt = try encode(source, job: job, quality: mid, maxPixels: pixels, strip: strip)
                        if attempt.data.count <= budget { (best, low) = (attempt, mid) } else { high = mid }
                    }
                    return best
                }
            }
            // Pixels scale with area, so shrink the edge by the square root of the overshoot.
            let edge = max(smallest.width, smallest.height)
            pixels = max(16, Int(Double(edge) * (Double(budget) / Double(smallest.data.count)).squareRoot() * 0.95))
            let shrunk = try encode(source, job: job, quality: preset, maxPixels: pixels, strip: strip)
            if shrunk.data.count <= budget { return shrunk }
            if shrunk.data.count < smallest.data.count { smallest = shrunk }
        }
        return smallest
    }

    /// One encode, in memory so budget retries never touch the disk.
    static func encode(_ source: CGImageSource, job: Job, quality: Double?, maxPixels: Int?, strip: Bool) throws -> Encoded {
        let frames = job.target == .gif ? CGImageSourceGetCount(source) : 1
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, job.target.contentType.identifier as CFString, frames, nil) else {
            throw ConvertError(.unsupportedPair, "This Mac can't write \(job.target.title) files.")
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        // PNG filter "sub": faster and smaller than the default on photos (research §2.1).
        if job.target == .png { options[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGCompressionFilter: 0x10] }
        if job.target == .tiff { options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }  // LZW
        if job.quality == .small { options[kCGImageDestinationOptimizeColorForSharing] = true }  // sRGB
        if frames > 1, let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
            let gif = file[kCGImagePropertyGIFDictionary]
        {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
        }
        var size = (0, 0)
        for index in 0..<frames {
            let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var perFrame = options
            if let gif = frame[kCGImagePropertyGIFDictionary] { perFrame[kCGImagePropertyGIFDictionary] = gif }
            if let maxPixels {
                // Thumbnail decode applies orientation, so the output is upright and tagged so.
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, thumbOptions as CFDictionary) else {
                    throw ConvertError(.corruptInput, "Couldn't decode \(job.input.lastPathComponent).")
                }
                size = (image.width, image.height)
                perFrame[kCGImagePropertyOrientation] = 1
                if !strip, let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
                    let upright = CGImageMetadataCreateMutableCopy(metadata)
                {
                    CGImageMetadataSetValueMatchingImageProperty(
                        upright, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
                    CGImageDestinationAddImageAndMetadata(destination, image, upright, perFrame as CFDictionary)
                } else {
                    CGImageDestinationAddImage(destination, image, perFrame as CFDictionary)
                }
            } else if strip {
                // A fresh image carries only what we pass: orientation, plus the ICC profile in its colour space.
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                    throw ConvertError(.corruptInput, "Couldn't decode \(job.input.lastPathComponent).")
                }
                size = (image.width, image.height)
                perFrame[kCGImagePropertyOrientation] = frame[kCGImagePropertyOrientation] ?? 1
                CGImageDestinationAddImage(destination, image, perFrame as CFDictionary)
            } else {
                size = (frame[kCGImagePropertyPixelWidth] as? Int ?? 0, frame[kCGImagePropertyPixelHeight] as? Int ?? 0)
                CGImageDestinationAddImageFromSource(destination, source, index, perFrame as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ConvertError(.internal, "ImageIO couldn't finish the \(job.target.title).", hint: "Try another target or quality.")
        }
        return Encoded(data: data as Data, width: size.0, height: size.1, quality: quality, maxPixels: maxPixels)
    }

    // MARK: Inspect and extract

    public static func inspect(_ url: URL, format: Format) async throws -> [String: JSONValue] {
        let source = try open(url)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var meta: [String: JSONValue] = [
            "width": .int(Int64(props[kCGImagePropertyPixelWidth] as? Int ?? 0)),
            "height": .int(Int64(props[kCGImagePropertyPixelHeight] as? Int ?? 0)),
            "has_alpha": .bool(props[kCGImagePropertyHasAlpha] as? Bool ?? false),
            "bit_depth": .int(Int64(props[kCGImagePropertyDepth] as? Int ?? 8)),
            "has_gps": .bool(props[kCGImagePropertyGPSDictionary] != nil),
            "orientation": .int(Int64(props[kCGImagePropertyOrientation] as? Int ?? 1)),
        ]
        if let space = (props[kCGImagePropertyProfileName] ?? props[kCGImagePropertyColorModel]) as? String {
            meta["color_space"] = .string(space)
        }
        let frames = CGImageSourceGetCount(source)
        if format == .gif || frames > 1 { meta["frames"] = .int(Int64(frames)) }
        return meta
    }

    public static func extract(_ url: URL, format: Format, as kind: ExtractKind, options: ExtractOptions) async throws -> String {
        guard let image = CGImageSourceCreateImageAtIndex(try open(url), 0, nil) else {
            throw ConvertError(.corruptInput, "Couldn't decode \(url.lastPathComponent).")
        }
        return try recognizeText(in: image)
    }

    /// Vision OCR, one line per observation. Falls back to the fast recognizer where the
    /// accurate one can't load its Neural Engine model (seen in sandboxed processes).
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            request.recognitionLevel = .fast
            try VNImageRequestHandler(cgImage: image).perform([request])
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
