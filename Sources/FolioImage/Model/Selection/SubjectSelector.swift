import CoreGraphics
import CoreImage
import CoreVideo
import FolioKit
import Synchronization
import Vision

/// Vision-backed shapes: subject (foreground instances, saliency as the fallback),
/// people (person instances and segmentation) and the sky heuristic.
///
/// Results are cached per image content, so re-rendering a selection (a new op, the
/// marching ants, a mask at another scale) runs Vision once. The first call loads the
/// model (about 2 s cold); call ``warmUp(_:)`` off the main thread after open.
nonisolated enum SubjectSelector {
    /// The mask for a `.subject`, `.people` or `.sky` shape at `image`'s size, or `nil`
    /// for other shapes or when nothing is found.
    static func mask(_ shape: SelectionSpec.Shape, in image: CGImage) throws -> CIImage? {
        let key = "\(fingerprint(image))|\(shape)"
        if let hit = results.withLock({ $0[key] }) { return hit }
        let found: CIImage?
        switch shape {
        case .subject(let instances): found = try subject(instances, in: image)
        case .people(let index): found = try people(index, in: image)
        case .sky: found = sky(in: image)
        default: return nil
        }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let mask = found.map { SelectionRenderer.stretched($0, to: extent) }
        results.withLock {
            if $0.count > 16 { $0.removeAll() }
            $0[key] = mask
        }
        return mask
    }

    /// The foreground instance under `point` (pixel coordinates of `image`, top-left), if any.
    static func instance(at point: CGPoint, in image: CGImage) throws -> Int? {
        let fg = try foreground(image)
        guard fg.labelWidth > 0, fg.labelHeight > 0 else { return nil }
        let x = Int(point.x / Double(image.width) * Double(fg.labelWidth))
        let y = Int(point.y / Double(image.height) * Double(fg.labelHeight))
        guard x >= 0, y >= 0, x < fg.labelWidth, y < fg.labelHeight else { return nil }
        let label = Int(fg.labels[y * fg.labelWidth + x])
        return label == 0 ? nil : label
    }

    /// Load the model and analyse `image` now, so the first click is fast.
    static func warmUp(_ image: CGImage) { _ = try? foreground(image) }

    // MARK: Subject

    private struct Foreground: Sendable {
        var labels: [UInt8] = []
        var labelWidth = 0
        var labelHeight = 0
        /// One mask per instance label, at the image's size.
        var masks: [Int: CIImage] = [:]
    }

    private static let foregrounds = Mutex<[Int: Foreground]>([:])
    private static let results = Mutex<[String: CIImage?]>([:])

    private static func foreground(_ image: CGImage) throws -> Foreground {
        let key = fingerprint(image)
        if let hit = foregrounds.withLock({ $0[key] }) { return hit }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try perform(request, on: handler)
        var fg = Foreground()
        if let observation = request.results?.first {
            let buffer = observation.instanceMask
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
            if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                fg.labels = (0..<h).flatMap { y in (0..<w).map { base[y * row + $0] } }
                fg.labelWidth = w
                fg.labelHeight = h
            }
            for instance in observation.allInstances {
                let mask = try observation.generateScaledMaskForImage(forInstances: [instance], from: handler)
                fg.masks[instance] = CIImage(cvPixelBuffer: mask)
            }
        }
        foregrounds.withLock {
            if $0.count > 2 { $0.removeAll() }
            $0[key] = fg
        }
        return fg
    }

    private static func subject(_ instances: [Int]?, in image: CGImage) throws -> CIImage? {
        let fg = try foreground(image)
        let chosen = (instances ?? fg.masks.keys.sorted()).compactMap { fg.masks[$0] }
        guard let mask = union(chosen) else { return instances == nil ? try salient(image) : nil }
        return mask
    }

    private static func union(_ masks: [CIImage]) -> CIImage? {
        guard let first = masks.first else { return nil }
        return masks.dropFirst().reduce(first) {
            $1.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0])
        }
    }

    /// Objectness saliency as a soft mask, for images with no clear foreground instance.
    private static func salient(_ image: CGImage) throws -> CIImage? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        try perform(request, on: VNImageRequestHandler(cgImage: image))
        guard let observation = request.results?.first, !(observation.salientObjects ?? []).isEmpty else { return nil }
        let heat = SelectionRenderer.stretched(
            CIImage(cvPixelBuffer: observation.pixelBuffer), to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // The heat map is coarse (about 68²) and soft; steepen it around 50 %.
        return MaskRefine.refine(heat, smooth: 1, scale: 1)
    }

    // MARK: People

    private static func people(_ index: Int?, in image: CGImage) throws -> CIImage? {
        let handler = VNImageRequestHandler(cgImage: image)
        guard let index else {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            try perform(request, on: handler)
            return request.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
        }
        let request = VNGeneratePersonInstanceMaskRequest()
        try perform(request, on: handler)
        // Instance labels start at 1.
        guard let observation = request.results?.first, observation.allInstances.contains(index + 1) else { return nil }
        return CIImage(cvPixelBuffer: try observation.generateScaledMaskForImage(forInstances: [index + 1], from: handler))
    }

    // MARK: Sky

    /// No system API selects sky, so this is a heuristic ("Select Sky (beta)"): grow from
    /// the top edge through pixels close to the top band's median color, changing only
    /// gradually, then remove any foreground subject.
    private static func sky(in image: CGImage) -> CIImage? {
        let lab = LabPixels(image)
        let w = lab.width, h = lab.height
        let band = (0..<(max(1, h / 25) * w)).map { lab[$0] }
        func median(_ k: Int) -> Float { band.map { $0[k] }.sorted()[band.count / 2] }
        let reference = SIMD3(median(0), median(1), median(2))
        let seeds = (0..<w).filter { lab.distanceSquared($0, reference) <= 20 * 20 }
        guard !seeds.isEmpty else { return nil }
        let bytes = MagicWand.flood(from: seeds, width: w, height: h) { from, to in
            lab.distanceSquared(to, from) <= 6 * 6 && lab.distanceSquared(to, reference) <= 35 * 35
        }
        guard var mask = SelectionRenderer.maskImage(bytes, width: w, height: h) else { return nil }
        // Without Vision the sky can still be selected, just without the subject cut out.
        if let subject = union((try? foreground(image)).map { Array($0.masks.values) } ?? []) {
            let extent = mask.extent
            mask = SelectionRenderer.stretched(subject, to: extent).applyingFilter("CIColorInvert")
                .applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
                .cropped(to: extent)
        }
        return mask
    }

    // MARK: Helpers

    private static func perform(_ request: VNRequest, on handler: VNImageRequestHandler) throws {
        do {
            try handler.perform([request])
        } catch {
            throw FolioError("Subject and sky selection aren't available on this Mac (\(error.localizedDescription)).")
        }
    }

    /// Identifies an image by its pixels, so re-rasterized copies hit the cache.
    static func fingerprint(_ image: CGImage) -> Int {
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        if let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: CFDataGetLength(data)))
        }
        return hasher.finalize()
    }
}
