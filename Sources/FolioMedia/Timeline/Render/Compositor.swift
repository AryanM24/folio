import AVFoundation
import CoreImage
import Metal

/// The custom `AVVideoCompositing` that draws every timeline frame, for the player, the
/// exporter, the image generator and the reader alike. Stateless apart from one shared
/// Metal-backed `CIContext`; everything it draws comes from the `FrameInstruction`.
nonisolated class Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "Folio timeline"]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    class var pixelFormat: OSType { kCVPixelFormatType_32BGRA }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [Self.pixelFormat], kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [Self.pixelFormat], kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var supportsWideColorSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? FrameInstruction,
            let time = Time(request.compositionTime), let output = request.renderContext.newPixelBuffer()
        else {
            return request.finish(with: FolioRenderError.badRequest)
        }
        let size = request.renderContext.size
        let image = Self.compose(instruction, at: time, size: size) { request.sourceFrame(byTrackID: $0) }
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = instruction.scene.colorSpace.cgColorSpace
        do {
            // Queue the GPU work and finish when it lands, so AVFoundation can ask for the next frame meanwhile.
            let task = try Self.context.startTask(toRender: image, to: destination)
            let pending = UncheckedSendable((request, output, task))
            Self.completion.async {
                let (request, output, task) = pending.value
                _ = try? task.waitUntilCompleted()
                request.finish(withComposedVideoFrame: output)
            }
        } catch {
            request.finish(with: error)
        }
    }

    private static let completion = DispatchQueue(label: "app.folio.timeline.compositor")

    // MARK: Drawing

    /// The frame at `time`, `size` pixels: background, then each item bottom to top, then captions.
    static func compose(
        _ instruction: FrameInstruction, at time: Time, size: CGSize, frame: (CMPersistentTrackID) -> CVPixelBuffer?
    ) -> CIImage {
        let scene = instruction.scene
        let canvas = CGRect(origin: .zero, size: size)
        let clear = CIImage(color: .clear).cropped(to: canvas)
        var image = CIImage(color: scene.background.ciColor).cropped(to: canvas)
        for item in instruction.items {
            switch item {
            case .layer(let layer):
                if let drawn = draw(layer, at: time, size: size, scene: scene, frame: frame) { image = drawn.composited(over: image) }
            case .transition(let transition, let window, let a, let b):
                let from = a.flatMap { draw($0, at: time, size: size, scene: scene, frame: frame) }?.composited(over: clear) ?? clear
                let to = b.flatMap { draw($0, at: time, size: size, scene: scene, frame: frame) }?.composited(over: clear) ?? clear
                let progress = window.duration > .zero ? (time - window.start).seconds / window.duration.seconds : 1
                image = Transitions.apply(transition, progress: progress, from: from, to: to, canvas: canvas).composited(over: image)
            }
        }
        if let captions = TextRenderer.captions(scene, at: time, size: size) { image = captions.composited(over: image) }
        return image.cropped(to: canvas)
    }

    /// One layer on a clear canvas: source → crop → effects → fit, scale, mask, rotate, flip,
    /// move → opacity, over its backdrop.
    static func draw(
        _ layer: RenderLayer, at time: Time, size: CGSize, scene: RenderScene, frame: (CMPersistentTrackID) -> CVPixelBuffer?
    ) -> CIImage? {
        let clip = layer.clip, transform = clip.transform
        let offset = time - clip.start
        let canvas = CGRect(origin: .zero, size: size)
        var title: TextRenderer.TitleFrame?
        var image: CIImage
        switch layer.content {
        case .track(let id, let orientation):
            guard let buffer = frame(id) else { return nil }
            image = oriented(CIImage(cvPixelBuffer: buffer), orientation)
        case .image(let id):
            guard let still = scene.images[id]?.value else { return nil }
            image = still
        case .color(let color): image = CIImage(color: color.ciColor).cropped(to: canvas)
        case .title(let t):
            let f = TextRenderer.title(t, offset: offset, duration: clip.duration, height: size.height)
            title = f
            image = f.image
        }
        guard !image.extent.isEmpty, !image.extent.isInfinite else { return nil }

        let crop = transform.crop.value(at: offset)
        if !crop.isZero {
            let e = image.extent
            let rect = CGRect(
                x: e.minX + crop.left * e.width, y: e.minY + crop.bottom * e.height,
                width: e.width * max(0, 1 - crop.left - crop.right), height: e.height * max(0, 1 - crop.top - crop.bottom))
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            image = image.cropped(to: rect)
        }
        let context = EffectGraph.Context(
            offset: offset, time: time, sourceTime: clip.sourceTime(atOffset: offset), source: layer.source, scene: scene)
        image = EffectGraph.apply(clip.effects, to: image, context)
        let e = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))

        // Fit, then the clip's own scale.
        let pixels = size.width / Double(scene.canvas.width)
        var (sx, sy): (Double, Double)
        switch (layer.content, transform.fit) {
        case (.title, _), (.color, _): (sx, sy) = (1, 1)
        case (_, .fit): sx = min(size.width / e.width, size.height / e.height); sy = sx
        case (_, .fill): sx = max(size.width / e.width, size.height / e.height); sy = sx
        case (_, .stretch): (sx, sy) = (size.width / e.width, size.height / e.height)
        case (_, .none): (sx, sy) = (pixels, pixels)
        }
        let s = transform.scale.value(at: offset) * (title?.scale ?? 1)
        let backdropSource = image
        image = image.transformed(by: CGAffineTransform(scaleX: sx * s, y: sy * s))
        if let mask = transform.mask { image = masked(image, mask) }

        // Rotate and flip about the centre, then move. Model y is down, Core Image's up.
        let w = image.extent.width, h = image.extent.height
        var position = transform.position.value(at: offset)
        position.x += title?.shift.x ?? 0
        position.y += title?.shift.y ?? 0
        let radians = -transform.rotation.value(at: offset) * .pi / 180
        image = image.transformed(
            by: CGAffineTransform(translationX: -w / 2, y: -h / 2)
                .concatenating(CGAffineTransform(scaleX: transform.flipHorizontal ? -1 : 1, y: transform.flipVertical ? -1 : 1))
                .concatenating(CGAffineTransform(rotationAngle: radians))
                .concatenating(CGAffineTransform(translationX: size.width * (0.5 + position.x), y: size.height * (0.5 - position.y))))

        switch transform.backdrop {
        case nil: break
        case .color(let color): image = image.composited(over: CIImage(color: color.ciColor).cropped(to: canvas))
        case .blurred(let radius):
            let b = backdropSource.extent
            let fill = max(size.width / b.width, size.height / b.height)
            let behind = backdropSource.transformed(
                by: CGAffineTransform(scaleX: fill, y: fill)
                    .concatenating(CGAffineTransform(translationX: (size.width - b.width * fill) / 2, y: (size.height - b.height * fill) / 2)))
            image = image.composited(over: behind.clampedToExtent().applyingGaussianBlur(sigma: radius * size.height).cropped(to: canvas))
        }

        let opacity = transform.opacity.value(at: offset) * (title?.opacity ?? 1)
        if opacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity))])
        }
        return image.cropped(to: canvas)
    }

    /// A decoded frame turned upright by the track's `preferredTransform` (which is y-down),
    /// with its extent back at the origin.
    static func oriented(_ image: CIImage, _ transform: CGAffineTransform) -> CIImage {
        guard !transform.isIdentity else { return image }
        let h = image.extent.height
        let shown = image.extent.applying(transform)
        let flip = { (height: Double) in CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height) }
        let upright = image.transformed(by: flip(h).concatenating(transform).concatenating(flip(shown.height)))
        return upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
    }

    private static func masked(_ image: CIImage, _ mask: LayerMask) -> CIImage {
        let e = image.extent
        let shape: CIImage?
        switch mask {
        case .roundedRect(let radius):
            let r = CIFilter.roundedRectangleGenerator()
            r.extent = e
            r.radius = Float(radius * min(e.width, e.height))
            r.color = .white
            shape = r.outputImage
        case .ellipse:
            // A unit circle with a 1 % soft edge, stretched over the layer.
            let g = CIFilter.radialGradient()
            g.center = .zero
            g.radius0 = 99
            g.radius1 = 100
            g.color0 = .white
            g.color1 = .clear
            shape = g.outputImage?.cropped(to: CGRect(x: -100, y: -100, width: 200, height: 200))
                .transformed(by: CGAffineTransform(scaleX: e.width / 200, y: e.height / 200))
                .transformed(by: CGAffineTransform(translationX: e.midX, y: e.midY))
        }
        guard let shape else { return image }
        return image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: shape])
    }
}

/// The compositor for HDR projects: half-float buffers so nothing clips at 1.0.
nonisolated final class HDRCompositor: Compositor, @unchecked Sendable {
    override class var pixelFormat: OSType { kCVPixelFormatType_64RGBAHalf }
    @objc var supportsHDRSourceFrames: Bool { true }
}

nonisolated enum FolioRenderError: Error {
    case badRequest
}
